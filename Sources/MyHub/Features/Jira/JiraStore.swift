import AppKit
import Observation

/// The Jira tab: connection, tickets assigned to the user, comments that
/// mention them, and their active sprint.
///
/// Refreshes when the tab comes into view and every 3 minutes while it stays
/// there. With "Notify on mentions" on, it also checks every 15 minutes in the
/// background and flashes the notch for a new mention. Nothing else runs.
@MainActor
@Observable
final class JiraStore {
    enum Connection: Equatable {
        case disconnected
        /// Checking the credentials just entered.
        case connecting
        /// Credentials rejected (expired or revoked token, 401).
        case expired
        case connected
    }

    enum View: String, CaseIterable, Sendable {
        case assigned, mentions, sprint

        var title: String {
            switch self {
            case .assigned: L10n.string("Assigned")
            case .mentions: L10n.string("Mentions")
            case .sprint: L10n.string("Sprint")
            }
        }
    }

    private(set) var connection: Connection
    private(set) var account: JiraAccount?
    private(set) var assigned: [JiraIssue] = []
    private(set) var mentions: [JiraMention] = []
    private(set) var sprint: JiraSprint?
    /// Loaded at least once since connecting; until then views show nothing
    /// rather than "empty".
    private(set) var hasLoaded = false
    private(set) var isRefreshing = false
    private(set) var lastSynced: Date?
    private(set) var problem: String?
    private(set) var boards: [(id: Int, name: String)] = []
    /// Boards with a sprint the user has tickets in; listed first.
    private(set) var myBoardIDs: Set<Int> = []
    var selectedIssue = 0
    /// Shown on the connect card.
    var setupVisible = false

    var view: View {
        didSet {
            preferences.update { $0.jira.view = view.rawValue }
            // Seen once the user moves on, so they stay highlighted while
            // being read.
            if oldValue == .mentions, view != .mentions { markMentionsRead() }
        }
    }

    /// A mention arrived while checking in the background.
    @ObservationIgnored var onNewMention: ((JiraMention) -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var visibleLoop: Task<Void, Never>?
    @ObservationIgnored private var backgroundLoop: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(preferences: Preferences) {
        self.preferences = preferences
        view = View(rawValue: preferences.values.jira.view) ?? .assigned
        let configured = !preferences.values.jira.site.isEmpty && (try? Keychain.secret(account: JiraClient.keychainAccount)) != nil
        connection = configured ? .connected : .disconnected
    }

    var settings: Preferences.Jira { preferences.values.jira }
    var site: JiraSite? { JiraSite(settings.site) }

    var unreadMentions: [JiraMention] {
        let read = Set(settings.readMentions)
        return mentions.filter { !read.contains($0.id) }
    }

    func isRead(_ mention: JiraMention) -> Bool { settings.readMentions.contains(mention.id) }

    private func client() -> JiraClient? {
        guard let site, let token = try? Keychain.secret(account: JiraClient.keychainAccount) else { return nil }
        return JiraClient(site: site, email: settings.email, token: token)
    }

    // MARK: - Lifecycle

    func start() {
        started = true
        updateBackground()
    }

    func stop() {
        started = false
        setVisible(false)
        backgroundLoop?.cancel()
        backgroundLoop = nil
    }

    func setVisible(_ visible: Bool) {
        if !visible, visibleLoop != nil, view == .mentions { markMentionsRead() }
        visibleLoop?.cancel()
        visibleLoop = nil
        guard visible, connection == .connected else { return }
        visibleLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                try? await Task.sleep(for: .seconds(180), tolerance: .seconds(20))
            }
        }
    }

    private func updateBackground() {
        backgroundLoop?.cancel()
        backgroundLoop = nil
        guard started, settings.notifyMentions, connection == .connected else { return }
        backgroundLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900), tolerance: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                if visibleLoop == nil { await refreshNow(announce: true) }
            }
        }
    }

    // MARK: - Connecting

    /// Checks the credentials against `/myself` before keeping them.
    func connect(site input: String, email: String, token: String) {
        guard let site = JiraSite(input) else {
            problem = L10n.string("Enter your Jira Cloud site, e.g. acme.atlassian.net")
            return
        }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !token.isEmpty else {
            problem = L10n.string("Enter the email you sign in with and an API token")
            return
        }
        problem = nil
        connection = .connecting
        preferences.update {
            $0.jira.site = site.host
            $0.jira.email = email
        }
        let client = JiraClient(site: site, email: email, token: Redacted(token))
        connectTask = Task { [weak self] in
            do {
                let me = try await client.myself()
                try Keychain.store(Redacted(token), account: JiraClient.keychainAccount)
                guard let self, !Task.isCancelled else { return }
                account = me
                connection = .connected
                setupVisible = false
                hasLoaded = false
                updateBackground()
                await refreshNow()
            } catch {
                guard let self, !Task.isCancelled else { return }
                connection = .disconnected
                setupVisible = true
                problem = Self.describe(error)
            }
        }
    }

    func cancelConnecting() {
        connectTask?.cancel()
        connection = .disconnected
    }

    func disconnect() {
        connectTask?.cancel()
        try? Keychain.remove(account: JiraClient.keychainAccount)
        preferences.update {
            $0.jira.site = ""
            $0.jira.boardID = nil
            $0.jira.readMentions = []
        }
        connection = .disconnected
        account = nil
        assigned = []
        mentions = []
        sprint = nil
        hasLoaded = false
        setVisible(false)
        updateBackground()
    }

    /// From the expired card: back to the form, site and email filled in.
    func reconnect() {
        connection = .disconnected
        setupVisible = true
    }

    func openTokenPage() {
        NSWorkspace.shared.open(URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
    }

    // MARK: - Loading

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refreshNow() }
    }

    private func refreshNow(announce: Bool = false) async {
        guard connection == .connected, let client = client() else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let me: JiraAccount
            if let account { me = account } else { me = try await client.myself() }
            account = me
            async let assigned = client.assigned()
            async let mentions = client.mentions(of: me)
            let boardID = settings.boardID
            async let sprint = client.activeSprint(boardID: boardID, account: me)
            let (a, m) = try await (assigned, mentions)
            let s = try? await sprint
            let before = Set(self.mentions.map(\.id))
            self.assigned = a
            self.mentions = m
            self.sprint = s ?? nil
            selectedIssue = min(selectedIssue, max(0, a.count - 1))
            hasLoaded = true
            lastSynced = Date()
            problem = nil
            if announce {
                let read = Set(settings.readMentions)
                for mention in m where !before.contains(mention.id) && !read.contains(mention.id) {
                    onNewMention?(mention)
                }
            }
        } catch UsageError.unauthorized {
            connection = .expired
            setVisible(false)
            updateBackground()
        } catch {
            problem = Self.describe(error)
        }
    }

    func loadBoards() {
        guard let client = client() else { return }
        Task { [weak self] in
            // The user's own boards first; then the site's first page, which
            // on a big site is mostly other teams'.
            async let mine = client.myBoards()
            async let site = client.boards()
            let own = (try? await mine) ?? []
            let rest = ((try? await site) ?? []).filter { board in !own.contains { $0.id == board.id } }
            self?.myBoardIDs = Set(own.map(\.id))
            self?.boards = own + rest.map { ($0.id, $0.name) }
        }
    }

    func setBoard(_ id: Int?) {
        preferences.update { $0.jira.boardID = id }
        refresh()
    }

    func setNotifyMentions(_ on: Bool) {
        preferences.update { $0.jira.notifyMentions = on }
        updateBackground()
    }

    /// For the inbox: mentions without touching the tab's own state.
    func refreshForInbox() async {
        if connection == .connected { await refreshNow() }
    }

    func markRead(_ ids: [String]) {
        let fresh = ids.filter { !settings.readMentions.contains($0) }
        guard !fresh.isEmpty else { return }
        preferences.update { $0.jira.readMentions = Array(($0.jira.readMentions + fresh).suffix(300)) }
    }

    private func markMentionsRead() {
        let ids = mentions.map(\.id).filter { !settings.readMentions.contains($0) }
        guard !ids.isEmpty else { return }
        preferences.update { $0.jira.readMentions = Array(($0.jira.readMentions + ids).suffix(300)) }
    }

    // MARK: - Actions

    func open(_ issue: JiraIssue) {
        if let url = site?.browse(issue.key) { openOnSite(url) }
    }

    func open(_ mention: JiraMention) {
        if let url = site?.browse(mention.issueKey, comment: mention.id) { openOnSite(url) }
    }

    /// "Open in Jira" for the current view.
    func openCurrentView() {
        guard let site else { return }
        switch view {
        case .assigned: openOnSite(site.search(JiraClient.assignedJQL) ?? site.url)
        case .mentions: openOnSite(site.url.appendingPathComponent("jira/your-work"))
        case .sprint: openOnSite(sprint.flatMap { site.board($0.boardID) } ?? site.url)
        }
    }

    private func openOnSite(_ url: URL) {
        guard site?.owns(url) == true else { return }
        NSWorkspace.shared.open(url)
    }

    func copyKey(_ issue: JiraIssue) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issue.key, forType: .string)
    }

    /// Posts a reply; returns whether it went through.
    func reply(to mention: JiraMention, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, JiraClient.isIssueKey(mention.issueKey), let client = client() else { return false }
        do {
            try await client.reply(to: mention.issueKey, text: trimmed)
            return true
        } catch UsageError.unauthorized {
            connection = .expired
            return false
        } catch {
            problem = Self.describe(error)
            return false
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UsageError.unauthorized: L10n.string("Jira didn't accept the email and token.")
        case UsageError.refused(let reason): reason
        case UsageError.network: L10n.string("Jira could not be reached.")
        default: L10n.string("Jira returned an error.")
        }
    }

    #if DEBUG
    func injectForPreview(connection: Connection, account: JiraAccount?, assigned: [JiraIssue], mentions: [JiraMention],
                          sprint: JiraSprint?, site: String = "acme.atlassian.net") {
        self.connection = connection
        self.account = account
        self.assigned = assigned
        self.mentions = mentions
        self.sprint = sprint
        hasLoaded = true
        lastSynced = Date().addingTimeInterval(-7200)
        preferences.update { $0.jira.site = site; $0.jira.email = "me@acme.com" }
    }
    #endif
}
