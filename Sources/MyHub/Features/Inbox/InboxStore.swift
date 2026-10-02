import AppKit
import Observation

/// The Inbox tab and the quiet badge on the closed notch: GitHub review
/// requests, reviews and comments on the user's pull requests, mentions, and
/// Jira mentions, and Figma comments and versions on watched files — newest
/// first, unread until opened.
///
/// Refreshes when the tab is shown and every 3 minutes while it is. With the
/// notch badge on, it also checks every 10 minutes in the background so the
/// count stays current. With neither a GitHub token nor Jira connected,
/// nothing runs.
@MainActor
@Observable
final class InboxStore {
    enum Filter: String, CaseIterable, Sendable {
        case all, github, jira, figma

        var title: String {
            switch self {
            case .all: L10n.string("All")
            case .github: "GitHub"
            case .jira: "Jira"
            case .figma: "Figma"
            }
        }
    }

    var filter: Filter = .all
    private(set) var github: [InboxItem] = []
    private(set) var isRefreshing = false
    private(set) var problem: String?
    private(set) var hasLoaded = false
    private(set) var hasGitHubToken = false
    private(set) var lastUpdated: Date?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let jira: JiraStore
    @ObservationIgnored let figma: FigmaStore
    @ObservationIgnored private var visibleLoop: Task<Void, Never>?
    @ObservationIgnored private var backgroundLoop: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(preferences: Preferences, jira: JiraStore, figma: FigmaStore) {
        self.preferences = preferences
        self.jira = jira
        self.figma = figma
    }

    // MARK: - Items

    /// Jira mentions are read live from the Jira store, so both tabs agree.
    private var jiraItems: [InboxItem] {
        guard jira.connection == .connected, let site = jira.site else { return [] }
        return jira.mentions.compactMap { mention in
            guard let url = site.browse(mention.issueKey, comment: mention.id) else { return nil }
            return InboxItem(id: "jira-\(mention.id)", source: .jira, kind: .mentioned, title: mention.issueSummary,
                             reference: mention.issueKey, actor: mention.author, snippet: mention.body, date: mention.created, url: url)
        }
    }

    private var figmaItems: [InboxItem] { figma.connection == .connected ? figma.items : [] }

    var all: [InboxItem] { InboxItem.merged([github, jiraItems, figmaItems]) }

    /// Filters with something behind them; Figma only once it's connected.
    var filters: [Filter] {
        Filter.allCases.filter { $0 != .figma || figma.connection != .disconnected }
    }

    var visible: [InboxItem] {
        switch filter {
        case .all: all
        case .github: github
        case .jira: jiraItems
        case .figma: figmaItems
        }
    }

    func isRead(_ item: InboxItem) -> Bool {
        switch item.source {
        case .github: preferences.values.inbox.read.contains(item.id)
        case .jira: preferences.values.jira.readMentions.contains(String(item.id.dropFirst("jira-".count)))
        case .figma: figma.isRead(item)
        }
    }

    var unreadCount: Int { all.filter { !isRead($0) }.count }

    func unread(in filter: Filter) -> Int {
        switch filter {
        case .all: unreadCount
        case .github: github.filter { !isRead($0) }.count
        case .jira: jiraItems.filter { !isRead($0) }.count
        case .figma: figmaItems.filter { !isRead($0) }.count
        }
    }

    /// Whether any source is set up; without one the tab explains what to do.
    var hasSources: Bool { hasGitHubToken || jira.connection == .connected || figma.connection == .connected }

    /// Shown on the closed notch.
    var badgeCount: Int { preferences.values.inbox.badge ? unreadCount : 0 }

    // MARK: - Lifecycle

    func start() {
        started = true
        hasGitHubToken = GitHubClient.storedToken() != nil
        updateBackground()
        if preferences.values.inbox.badge, hasSources { refresh() }
    }

    func stop() {
        started = false
        visibleLoop?.cancel()
        visibleLoop = nil
        backgroundLoop?.cancel()
        backgroundLoop = nil
    }

    func setVisible(_ visible: Bool) {
        visibleLoop?.cancel()
        visibleLoop = nil
        guard visible else { return }
        hasGitHubToken = GitHubClient.storedToken() != nil
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
        guard started, preferences.values.inbox.badge else { return }
        backgroundLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600), tolerance: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                if visibleLoop == nil, hasSources { await refreshNow() }
            }
        }
    }

    func setBadge(_ on: Bool) {
        preferences.update { $0.inbox.badge = on }
        updateBackground()
    }

    // MARK: - Loading

    func refresh() {
        Task { [weak self] in await self?.refreshNow() }
    }

    private func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let token = GitHubClient.storedToken()
        hasGitHubToken = token != nil
        async let jiraDone: Void = jira.refreshForInbox()
        async let figmaDone: Void = figma.refreshForInbox()
        if token != nil {
            do {
                github = try await GitHubClient(token: token).inbox()
                problem = nil
            } catch UsageError.unauthorized {
                problem = L10n.string("GitHub refused the token. Check it on the Dev → Git page.")
            } catch UsageError.rateLimited {
                problem = L10n.string("GitHub rate limit reached; trying again later.")
            } catch {
                problem = L10n.string("GitHub could not be reached.")
            }
        } else {
            github = []
        }
        await jiraDone
        await figmaDone
        hasLoaded = true
        lastUpdated = Date()
        pruneReadState()
    }

    /// Forget read marks for items that have left the window.
    private func pruneReadState() {
        let current = Set(github.map(\.id))
        let read = preferences.values.inbox.read
        let kept = read.filter(current.contains)
        if kept.count < read.count, hasLoaded, !github.isEmpty { preferences.update { $0.inbox.read = kept } }
    }

    // MARK: - Actions

    func open(_ item: InboxItem) {
        markRead([item])
        let safe: Bool = switch item.source {
        case .github: GitHubDecoding.safeWebURL(item.url.absoluteString) != nil
        case .jira: jira.site?.owns(item.url) == true
        case .figma: FigmaLink.isSafeWebURL(item.url)
        }
        if safe { NSWorkspace.shared.open(item.url) }
    }

    func markRead(_ items: [InboxItem]) {
        let githubIDs = items.filter { $0.source == .github }.map(\.id).filter { !preferences.values.inbox.read.contains($0) }
        if !githubIDs.isEmpty { preferences.update { $0.inbox.read = Array(($0.inbox.read + githubIDs).suffix(500)) } }
        jira.markRead(items.filter { $0.source == .jira }.map { String($0.id.dropFirst("jira-".count)) })
        figma.markRead(items)
    }

    func markAllRead() { markRead(visible) }

    #if DEBUG
    func injectForPreview(_ items: [InboxItem]) {
        github = items
        hasGitHubToken = true
        hasLoaded = true
        lastUpdated = Date().addingTimeInterval(-120)
    }
    #endif
}
