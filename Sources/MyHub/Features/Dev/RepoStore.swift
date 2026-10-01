import AppKit
import Observation

/// Pinned Git working copies: their local state (branch, ahead/behind,
/// changes), the open pull request for the current branch, and recent GitHub
/// Actions runs.
///
/// Local state comes from `git` and costs nothing to refresh, so it is read
/// whenever the Git page comes into view. GitHub is asked only on that same
/// occasion, plus — with "watch CI" on — every so often while a run is in
/// progress, so the notch can say when it finishes. Nothing polls while no
/// run is going.
@MainActor
@Observable
final class RepoStore {
    struct Repo: Identifiable, Equatable {
        let path: String
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var status: GitStatus?
        var lastCommit: String?
        var github: GitHubRepo?
        var pull: PullRequestInfo?
        var problem: String?
    }

    private(set) var repos: [Repo] = []
    private(set) var runs: [WorkflowRun] = []
    private(set) var isRefreshing = false
    private(set) var githubProblem: String?
    private(set) var toolsMissing = false
    private(set) var hasToken = false

    /// A watched run finished.
    @ObservationIgnored var onRunFinished: ((WorkflowRun) -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var started = false

    init(preferences: Preferences) {
        self.preferences = preferences
        repos = preferences.values.dev.repos.map { Repo(path: $0) }
    }

    var runningCount: Int { runs.filter(\.isRunning).count }

    // MARK: - Lifecycle

    func start() {
        started = true
        hasToken = GitHubClient.storedToken() != nil
    }

    func stop() {
        started = false
        refreshTask?.cancel()
        watchTask?.cancel()
        watchTask = nil
    }

    /// The Git or CI page came into view.
    func pageShown() {
        if Date().timeIntervalSince(lastRefresh) > 20 { refresh() }
    }

    // MARK: - Repositories

    /// Asks for a folder with the standard open panel. MyHub never activates
    /// on its own, so it does here — a dialog behind other windows is lost.
    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.string("Add")
        panel.message = L10n.string("Choose Git working copies to show in MyHub")
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { self?.add(urls) }
        }
    }

    func add(_ urls: [URL]) {
        Task { [weak self] in
            for url in urls {
                // The repository root, even when a subfolder was picked.
                guard let out = try? await CommandRunner.run("/usr/bin/git", ["-C", url.path, "rev-parse", "--show-toplevel"]),
                      out.succeeded else { continue }
                let root = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, !root.isEmpty, !repos.contains(where: { $0.path == root }) else { continue }
                repos.append(Repo(path: root))
            }
            self?.savePaths()
            self?.refresh()
        }
    }

    func remove(_ path: String) {
        repos.removeAll { $0.path == path }
        runs.removeAll { run in !repos.contains { $0.github == run.repo } }
        savePaths()
    }

    private func savePaths() {
        preferences.update { $0.dev.repos = repos.map(\.path) }
    }

    func reveal(_ repo: Repo) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
    }

    func openInTerminal(_ repo: Repo) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: repo.path, isDirectory: true)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Only links that came from GitHub's API and point at github.com.
    func openOnGitHub(_ url: URL) {
        guard GitHubDecoding.safeWebURL(url.absoluteString) != nil else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Token

    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try Keychain.store(Redacted(trimmed), account: GitHubClient.keychainAccount)
            hasToken = true
            githubProblem = nil
            refresh()
        } catch {
            githubProblem = L10n.string("Could not save the token to the Keychain.")
        }
    }

    func removeToken() {
        try? Keychain.remove(account: GitHubClient.keychainAccount)
        hasToken = false
    }

    // MARK: - Refreshing

    func refresh() {
        refreshTask?.cancel()
        isRefreshing = true
        lastRefresh = Date()
        let paths = repos.map(\.path)
        refreshTask = Task { [weak self] in
            guard await CommandRunner.developerToolsInstalled() else {
                self?.toolsMissing = true
                self?.isRefreshing = false
                return
            }
            self?.toolsMissing = false
            // Local state first — it is instant and shows even offline.
            var local: [String: Repo] = [:]
            await withTaskGroup(of: Repo.self) { group in
                for path in paths { group.addTask { await Self.readLocal(path) } }
                for await repo in group { local[repo.path] = repo }
            }
            guard let self, !Task.isCancelled else { return }
            repos = repos.map { old in local[old.path].map { var new = $0; new.pull = old.pull; return new } ?? old }
            await refreshGitHub()
            isRefreshing = false
        }
    }

    private func refreshGitHub() async {
        let client = GitHubClient(token: GitHubClient.storedToken())
        hasToken = client.token != nil
        var allRuns: [WorkflowRun] = []
        var problem: String?
        for repo in repos {
            guard let github = repo.github else { continue }
            if let branch = repo.status?.branch {
                do {
                    let pull = try await client.pullRequest(github, branch: branch)
                    update(repo.path) { $0.pull = pull }
                } catch {
                    problem = Self.describe(error)
                }
            }
            if let fetched = try? await client.runs(github) { allRuns += fetched }
            if Task.isCancelled { return }
        }
        githubProblem = problem
        let previous = runs
        runs = allRuns.sorted { $0.started > $1.started }
        announceFinished(previous: previous)
        scheduleWatch()
    }

    private func update(_ path: String, _ change: (inout Repo) -> Void) {
        if let index = repos.firstIndex(where: { $0.path == path }) { change(&repos[index]) }
    }

    nonisolated private static func readLocal(_ path: String) async -> Repo {
        var repo = Repo(path: path)
        guard FileManager.default.fileExists(atPath: path) else {
            repo.problem = L10n.string("Folder not found")
            return repo
        }
        let git = "/usr/bin/git"
        async let status = CommandRunner.run(git, ["-C", path, "status", "--porcelain=v2", "--branch"])
        async let log = CommandRunner.run(git, ["-C", path, "log", "-1", "--format=%s\u{1F}%cr"])
        async let remote = CommandRunner.run(git, ["-C", path, "remote", "get-url", "origin"])
        if let out = try? await status, out.succeeded {
            repo.status = GitStatus.parse(out.stdout)
        } else {
            repo.problem = (try? await status)?.failureReason ?? L10n.string("Not a Git repository")
        }
        if let out = try? await log, out.succeeded {
            let parts = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1F}")
            repo.lastCommit = parts.count == 2 ? "\(parts[0]) · \(parts[1])" : nil
        }
        if let out = try? await remote, out.succeeded { repo.github = GitHubRepo(remote: out.stdout) }
        return repo
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UsageError.unauthorized: L10n.string("GitHub refused the token (or the rate limit was reached without one).")
        case UsageError.rateLimited: L10n.string("GitHub rate limit reached. Add a token for more requests.")
        default: L10n.string("GitHub could not be reached.")
        }
    }

    // MARK: - Watching CI

    /// Runs that were in progress and now are not, flashed once each.
    private func announceFinished(previous: [WorkflowRun]) {
        let wasRunning = Set(previous.filter(\.isRunning).map(\.id))
        for run in runs where wasRunning.contains(run.id) && !run.isRunning {
            onRunFinished?(run)
        }
    }

    /// While a run is in progress (and watching is on), check again every
    /// half minute with a token, every 90 s without one (the anonymous limit
    /// is 60 requests an hour). Stops by itself when nothing is running.
    private func scheduleWatch() {
        watchTask?.cancel()
        watchTask = nil
        guard started, preferences.values.dev.watchCI, runningCount > 0 else { return }
        let interval: Duration = hasToken ? .seconds(30) : .seconds(90)
        watchTask = Task { [weak self] in
            try? await Task.sleep(for: interval, tolerance: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            await pollRuns()
        }
    }

    private func pollRuns() async {
        let client = GitHubClient(token: GitHubClient.storedToken())
        let watched = Set(runs.filter(\.isRunning).map(\.repo))
        var fresh = runs.filter { !watched.contains($0.repo) }
        for repo in watched {
            if let fetched = try? await client.runs(repo) { fresh += fetched } else { fresh += runs.filter { $0.repo == repo } }
        }
        let previous = runs
        runs = fresh.sorted { $0.started > $1.started }
        announceFinished(previous: previous)
        scheduleWatch()
    }

    func setWatchCI(_ on: Bool) {
        preferences.update { $0.dev.watchCI = on }
        scheduleWatch()
    }

    #if DEBUG
    func injectForPreview(_ repos: [Repo], runs: [WorkflowRun]) {
        self.repos = repos
        self.runs = runs
    }
    #endif
}
