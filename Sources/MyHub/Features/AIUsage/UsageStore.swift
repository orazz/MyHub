import Foundation
import Observation

/// The AI Usage section's state: configured accounts, their latest snapshots
/// and errors, and when to ask again.
///
/// Nothing runs while the section is not on screen. While it is, a refresh
/// is attempted every minute; the engine turns most of those into no-ops
/// (each source has its own minimum interval, and failures back off).
@MainActor
@Observable
final class UsageStore {
    private(set) var snapshots: [String: UsageSnapshot] = [:]
    private(set) var errors: [String: UsageError] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let engine = UsageEngine()
    @ObservationIgnored private var claudeLedgers: [String: LogLedger<ClaudeUsageRecord>] = [:]
    @ObservationIgnored private var codexLedgers: [String: LogLedger<CodexUsageRecord>] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var visibleLoop: Task<Void, Never>?
    @ObservationIgnored private var backgroundLoop: Task<Void, Never>?
    @ObservationIgnored private var alertLedger = AlertLedger(fired: Set(UserDefaults.standard.stringArray(forKey: "usage.firedAlerts") ?? []))

    /// After every refresh, with the alerts it produced (empty when alerts
    /// are off). The menu bar meter and the notifier listen here.
    @ObservationIgnored var onRefreshed: (([UsageAlert]) -> Void)?

    /// Off in tests, so adding a source never reaches the network or the Keychain.
    @ObservationIgnored private let refreshesOnAdd: Bool
    /// Where secrets go; replaced in tests.
    @ObservationIgnored var storeSecret: (Redacted<String>, String) throws -> Void = { try Keychain.store($0, account: $1) }

    /// The source list is showing (instead of the cards).
    var isPicking = false
    /// The provider segment on screen.
    var selectedGroupID: String?

    var groups: [UsageGroup] { UsageGroup.build(accounts) }

    var selectedGroup: UsageGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    func summary(for group: UsageGroup) -> UsageSummary {
        UsageSummary.build(group: group, snapshots: snapshots, errors: errors)
    }
    /// A key-based source being set up.
    var draft: SourceDraft?
    private(set) var draftError: String?

    init(preferences: Preferences, refreshesOnAdd: Bool = true) {
        self.preferences = preferences
        self.refreshesOnAdd = refreshesOnAdd
    }

    var accounts: [UsageAccount] { preferences.values.usage.accounts }

    /// The fullest window across every account — what the header shows.
    var headline: QuotaWindow? {
        snapshots.values.compactMap(\.highestWindow).max { $0.used < $1.used }
    }

    // MARK: - Accounts

    struct SourceChoice: Identifiable, Equatable {
        var id: ProviderKind { kind }
        let kind: ProviderKind
        let detected: Bool
        let added: Bool
    }

    /// Found on this Mac; refreshed when the source list appears.
    private(set) var detected: Set<ProviderKind> = []

    func refreshDetected() {
        detected = Set(detectedSources())
    }

    /// Detected first, then the rest that work today, then what is coming.
    var sourceChoices: [SourceChoice] {
        let added = Set(accounts.map(\.kind))
        return ProviderKind.allCases
            .map { SourceChoice(kind: $0, detected: detected.contains($0), added: added.contains($0) && !$0.allowsMultiple) }
            .sorted { rank($0) < rank($1) }
    }

    private func rank(_ choice: SourceChoice) -> Int {
        if !choice.kind.isAvailable { return 3 }
        if choice.added { return 2 }
        return choice.detected ? 0 : 1
    }

    /// A row's Add button: local sources are added at once, key-based ones
    /// open the setup form.
    func choose(_ kind: ProviderKind) {
        if kind.needsSetup {
            draft = SourceDraft(kind: kind)
            draftError = nil
        } else {
            add(kind)
        }
    }

    func cancelDraft() {
        draft = nil
        draftError = nil
    }

    func saveDraft() {
        guard let draft else { return }
        if let problem = draft.problem {
            draftError = problem
            return
        }
        let id = UUID().uuidString
        if let secret = draft.secretToStore {
            do {
                try storeSecret(secret, id)
            } catch {
                draftError = L10n.string("Could not save the key to the Keychain.")
                return
            }
        }
        let label = draft.label.trimmingCharacters(in: .whitespaces)
        let account = UsageAccount(id: id, kind: draft.kind, label: label.isEmpty ? draft.kind.title : label, options: draft.options)
        preferences.update { $0.usage.accounts.append(account) }
        self.draft = nil
        draftError = nil
        isPicking = false
        if refreshesOnAdd { refresh(force: true) }
    }

    func add(_ kind: ProviderKind) {
        guard kind.isAvailable, !kind.needsSetup else { return }
        // A Mac has one Claude Code and one Codex: a second card would show
        // the same numbers. API sources (next phase) allow one per key.
        guard kind.allowsMultiple || !accounts.contains(where: { $0.kind == kind }) else { return }
        let account = UsageAccount(id: UUID().uuidString, kind: kind, label: kind.title)
        preferences.update { $0.usage.accounts.append(account) }
        if refreshesOnAdd { refresh(force: true) }
    }

    func remove(_ id: String) {
        preferences.update { $0.usage.accounts.removeAll { $0.id == id } }
        snapshots[id] = nil
        errors[id] = nil
        claudeLedgers[id] = nil
        codexLedgers[id] = nil
        try? Keychain.remove(account: id)
        Task { [engine] in await engine.forget(id) }
    }

    /// Sources found on this Mac and not yet added. Checks only for the
    /// presence of files and of the Keychain item — never reads a secret.
    func detectedSources() -> [ProviderKind] {
        let fm = FileManager.default
        var found: [ProviderKind] = []
        if Keychain.foreignItemExists(service: ClaudePlanProvider.keychainService) { found.append(.claudePlan) }
        if !ClaudeLogsProvider.defaultRoots().isEmpty { found.append(.claudeLogs) }
        if fm.fileExists(atPath: CodexHome.url.appendingPathComponent("auth.json").path) { found.append(.codexPlan) }
        if fm.fileExists(atPath: CodexHome.url.appendingPathComponent("sessions").path) { found.append(.codexLogs) }
        return found
    }

    #if DEBUG
    /// Tests and layout previews only.
    func inject(_ snapshot: UsageSnapshot) { snapshots[snapshot.accountID] = snapshot }
    #endif

    // MARK: - Refreshing

    /// Called when the section's visibility changes.
    func setVisible(_ visible: Bool) {
        visibleLoop?.cancel()
        visibleLoop = nil
        guard visible else { return }
        visibleLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh(force: false)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// With the menu bar meter or alerts on, usage is worth knowing while the
    /// panel is closed too — but every quarter hour is plenty, and each
    /// source still keeps its own minimum interval and backoff.
    func setBackground(_ enabled: Bool) {
        backgroundLoop?.cancel()
        backgroundLoop = nil
        guard enabled else { return }
        backgroundLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh(force: false)
                try? await Task.sleep(for: .seconds(15 * 60), tolerance: .seconds(60))
            }
        }
    }

    private func evaluateAlerts() -> [UsageAlert] {
        guard preferences.values.usage.alerts else { return [] }
        let items = accounts.compactMap { account in snapshots[account.id].map { (account: account, snapshot: $0) } }
        let alerts = alertLedger.evaluate(items, now: Date())
        if !alerts.isEmpty {
            alertLedger.trim()
            UserDefaults.standard.set(Array(alertLedger.fired), forKey: "usage.firedAlerts")
        }
        return alerts
    }

    func refresh(force: Bool) {
        guard refreshTask == nil else { return }
        let providers = accounts.filter(\.enabled).compactMap(provider(for:))
        guard !providers.isEmpty else { return }
        isRefreshing = true
        refreshTask = Task { [weak self, engine] in
            let outcomes = await engine.refresh(providers, now: Date(), force: force)
            guard let self else { return }
            for outcome in outcomes {
                switch outcome.result {
                case .success(let snapshot):
                    snapshots[outcome.accountID] = snapshot
                    errors[outcome.accountID] = nil
                case .failure(let error):
                    // The last good snapshot stays on screen, marked stale.
                    errors[outcome.accountID] = error
                case nil:
                    break
                }
            }
            lastRefresh = Date()
            isRefreshing = false
            refreshTask = nil
            onRefreshed?(evaluateAlerts())
        }
    }

    private func provider(for account: UsageAccount) -> (any UsageProvider)? {
        switch account.kind {
        case .claudePlan:
            return ClaudePlanProvider(accountID: account.id)
        case .claudeLogs:
            let ledger = claudeLedgers[account.id] ?? ClaudeLogsProvider.makeLedger()
            claudeLedgers[account.id] = ledger
            return ClaudeLogsProvider(accountID: account.id, ledger: ledger)
        case .codexPlan:
            return CodexPlanProvider(accountID: account.id)
        case .codexLogs:
            let ledger = codexLedgers[account.id] ?? CodexLogsProvider.makeLedger()
            codexLedgers[account.id] = ledger
            return CodexLogsProvider(accountID: account.id, ledger: ledger)
        case .anthropicAdmin:
            return AnthropicAdminProvider(accountID: account.id, key: { try Self.requiredSecret(account.id) })
        case .openAIAdmin:
            return OpenAIAdminProvider(accountID: account.id, key: { try Self.requiredSecret(account.id) })
        case .openRouter:
            return OpenRouterProvider(accountID: account.id, key: { try Self.requiredSecret(account.id) })
        case .bedrock:
            let id = account.id
            let profile = account.options["profile"] ?? "default"
            let useProfile = account.options["credentials"] == "profile"
            return BedrockProvider(
                accountID: id,
                region: account.options["region"] ?? "us-east-1",
                includeCost: account.options["cost"] == "on",
                credentials: { useProfile ? try AWSCredentialSource.profile(profile) : try AWSCredentialSource.keychain(account: id) }
            )
        case .custom:
            let id = account.id
            return CustomEndpointProvider(accountID: id, config: CustomEndpointConfig(options: account.options),
                                          key: { try Keychain.secret(account: id) })
        }
    }

    /// Read on each fetch, off the main actor; never cached.
    nonisolated static func requiredSecret(_ account: String) throws -> Redacted<String> {
        guard let secret = try? Keychain.secret(account: account), !secret.isEmpty else {
            throw UsageError.notConfigured(L10n.string("The key is missing from the Keychain — remove this source and add it again."))
        }
        return secret
    }
}
