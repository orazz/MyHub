import AppKit
import Observation

/// The Builds tab: the build running now, recent results, and the caches
/// that grow behind them. Everything is read from what Xcode and Gradle leave
/// on disk and in the process table — no plugins, nothing to install.
///
/// Polls every two seconds while the tab is on screen. With "Notify when
/// build finishes" on, a slower poll (every ten seconds) keeps running so the
/// notch can flash when a build ends.
@MainActor
@Observable
final class BuildStore {
    enum Platform: String, Sendable { case xcode, android }
    /// The build running now, or the BuildWatch-style statistics.
    enum Mode: String, Sendable { case now, stats }

    var platform: Platform = .xcode
    var mode: Mode = .now
    var statsRange: BuildStats.Range = .week
    var statsMetric: BuildStats.Metric = .total
    /// Bars split by scheme (stacked) or combined.
    var splitBySchemes = true
    private(set) var history: BuildHistory
    private(set) var current: CurrentBuild?
    private(set) var recent: [BuildRecord] = []
    private(set) var cacheBytes: [Platform: Int64] = [:]
    private(set) var daemons = 0
    var confirmingClear = false
    private(set) var isClearing = false

    /// Raised when a build ends, with its result when one can be found.
    @ObservationIgnored var onFinished: ((BuildRecord?) -> Void)?
    /// New builds were recorded (the menu bar's "today" figure moves).
    @ObservationIgnored var onHistoryChange: (() -> Void)?
    @ObservationIgnored private let historyFile: URL
    @ObservationIgnored private let saves = WriteCoalescer(delay: .seconds(2))

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var visibleLoop: Task<Void, Never>?
    @ObservationIgnored private var backgroundLoop: Task<Void, Never>?
    @ObservationIgnored private var sizeTask: Task<Void, Never>?
    @ObservationIgnored private var sizesMeasured: [Platform: Date] = [:]
    @ObservationIgnored private var wasBuilding: [Platform: Date] = [:]
    @ObservationIgnored private var mergedGeneration = -1

    init(preferences: Preferences, historyFile: URL = AppPaths.file("build-history.json")) {
        self.preferences = preferences
        self.historyFile = historyFile
        self.history = BuildHistory.load(from: historyFile)
        platform = preferences.values.builds.tool == .android ? .android : .xcode
    }

    /// Build time today, every platform — the menu bar figure.
    var todayTotal: TimeInterval { BuildStats.today(history.records, now: Date()) }

    /// The statistics for the chosen range, without the schemes the user
    /// switched off in the legend.
    func summary(now: Date = Date()) -> BuildStats.Summary {
        cachedStats(now: now).summary
    }

    /// Every scheme with builds in the range, hidden or not, largest first —
    /// the legend's chips, and the order that fixes their colours.
    func schemesInRange(now: Date = Date()) -> [(name: String, seconds: TimeInterval)] {
        cachedStats(now: now).schemes
    }

    /// The chart is redrawn on every pointer move over its bars; working the
    /// statistics out again over the whole history each time is wasted. They
    /// only change with the history, the range, the hidden schemes, the tool
    /// — or the minute, for "today" and the bucket edges.
    @ObservationIgnored private var statsCache: (key: String, summary: BuildStats.Summary, schemes: [(name: String, seconds: TimeInterval)])?

    private func cachedStats(now: Date) -> (summary: BuildStats.Summary, schemes: [(name: String, seconds: TimeInterval)]) {
        let hiddenList = preferences.values.builds.hiddenSchemes
        let key = [String(history.records.count), history.records.first?.id ?? "", statsRange.rawValue,
                   hiddenList.joined(separator: "\u{1F}"), tool.rawValue, String(Int(now.timeIntervalSince1970 / 60))]
            .joined(separator: "|")
        if let statsCache, statsCache.key == key { return (statsCache.summary, statsCache.schemes) }
        let hidden = Set(hiddenList)
        let watchedRecords = history.records.filter { watched(platform: $0.platform) }
        let summary = BuildStats.summary(watchedRecords.filter { !hidden.contains($0.scheme) }, range: statsRange, now: now)
        let schemes = hidden.isEmpty ? summary.schemes : BuildStats.summary(watchedRecords, range: statsRange, now: now).schemes
        statsCache = (key, summary, schemes)
        return (summary, schemes)
    }

    func isSchemeHidden(_ scheme: String) -> Bool {
        preferences.values.builds.hiddenSchemes.contains(scheme)
    }

    func toggleScheme(_ scheme: String) {
        preferences.update { values in
            var hidden = Set(values.builds.hiddenSchemes)
            if hidden.remove(scheme) == nil { hidden.insert(scheme) }
            values.builds.hiddenSchemes = hidden.sorted()
        }
    }

    func showAllSchemes() {
        preferences.update { $0.builds.hiddenSchemes = [] }
    }

    private func watched(platform: BuildRecord.Platform) -> Bool {
        switch tool {
        case .xcode: platform == .xcode
        case .android: platform == .android
        case .both: true
        }
    }

    /// Before quitting.
    func flush() { saves.flush() }

    #if DEBUG
    /// Snapshots only: which bar to draw as hovered.
    var previewHoverIndex: Int?

    /// Previews and snapshots only — never written to disk.
    func injectHistoryForPreview(_ records: [BuildRecord]) {
        history.merge(records)
        recent = Array(history.records.prefix(8))
    }
    #endif

    var tool: Preferences.Builds.Tool { preferences.values.builds.tool }

    // MARK: - Polling

    func setVisible(_ visible: Bool) {
        visibleLoop?.cancel()
        visibleLoop = nil
        guard visible else { return }
        confirmingClear = false
        measureSizesIfStale()
        visibleLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(300))
            }
        }
    }

    func setBackground(_ enabled: Bool) {
        backgroundLoop?.cancel()
        backgroundLoop = nil
        guard enabled else { return }
        backgroundLoop = Task { [weak self] in
            while !Task.isCancelled {
                if self?.visibleLoop == nil { await self?.poll() }
                try? await Task.sleep(for: .seconds(10), tolerance: .seconds(2))
            }
        }
    }

    func selectPlatform(_ next: Platform) {
        platform = next
        confirmingClear = false
        Task { await poll() }
        measureSizesIfStale()
    }

    private var watchedPlatforms: [Platform] {
        switch tool {
        case .xcode: [.xcode]
        case .android: [.android]
        case .both: [.xcode, .android]
        }
    }

    func poll() async {
        let shown = platform
        let watched = watchedPlatforms
        let result = await Task.detached(priority: .utility) { () -> [Platform: (CurrentBuild?, [BuildRecord], Int)] in
            var out: [Platform: (CurrentBuild?, [BuildRecord], Int)] = [:]
            for platform in watched {
                out[platform] = platform == .xcode ? Self.readXcode() : Self.readGradle()
            }
            return out
        }.value

        // Merging builds a set of every stored id; skip it when no Xcode
        // manifest changed and Gradle isn't watched (its logs aren't cached).
        let generation = XcodeBuilds.manifestCache.generation
        let unchanged = generation == mergedGeneration && !watched.contains(.android)
        mergedGeneration = generation
        let seen = unchanged ? [] : result.values.flatMap { $0.1 }
        if !unchanged, self.history.merge(seen) {
            let snapshot = self.history, file = historyFile
            saves.schedule { Task.detached(priority: .utility) { snapshot.save(to: file) } }
            onHistoryChange?()
        }
        let shownPlatform: BuildRecord.Platform = shown == .xcode ? .xcode : .android
        // Assigning an @Observable property re-renders whoever reads it, even
        // with an equal value; on a 2-second poll that is most of the cost.
        let freshRecent = Array(self.history.records.lazy.filter { $0.platform == shownPlatform }.prefix(8))
        if freshRecent != recent { recent = freshRecent }

        for (platform, (running, history, daemonCount)) in result {
            if platform == shown {
                if current != running { current = running }
                if daemons != daemonCount { daemons = daemonCount }
            }
            if let started = wasBuilding[platform], running == nil {
                wasBuilding[platform] = nil
                // The result lands on disk a moment after the processes exit.
                let record = history.first { $0.finished >= started.addingTimeInterval(-5) }
                if record != nil || platform == .android {
                    onFinished?(record)
                } else {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(3))
                        let late = await Task.detached { XcodeBuilds.recentBuilds(limit: 1) }.value.first
                        self?.onFinished?(late.flatMap { $0.finished >= started.addingTimeInterval(-5) ? $0 : nil })
                    }
                }
            } else if let running {
                wasBuilding[platform] = wasBuilding[platform] ?? running.startedAt
            }
        }
    }

    nonisolated private static func readXcode() -> (CurrentBuild?, [BuildRecord], Int) {
        // Every build Xcode still has a record of; the history keeps them
        // once Xcode prunes its logs.
        let history = XcodeBuilds.recentBuilds(limit: 5000)
        let jobs = XcodeBuilds.activeJobs(in: ProcessScanner.all())
        guard !jobs.isEmpty else { return (nil, history, 0) }
        let project = XcodeBuilds.activeProject() ?? "Xcode"
        let same = history.filter { $0.name.hasPrefix(project) && $0.status == .success }.map(\.duration)
        let average = same.isEmpty ? nil : same.reduce(0, +) / Double(same.count)
        let compiling = jobs.filter { $0.name != "xcodebuild" }.count
        let viaCLI = jobs.contains { $0.name == "xcodebuild" }
        return (CurrentBuild(
            target: project,
            detail: viaCLI ? "xcodebuild" : "Xcode",
            startedAt: BuildClock.shared.start(for: "xcode:\(project)"),
            averageDuration: average,
            step: compiling > 0 ? L10n.format("%d build jobs running", compiling) : L10n.string("Preparing build")
        ), history, 0)
    }

    nonisolated private static func readGradle() -> (CurrentBuild?, [BuildRecord], Int) {
        let pids = GradleBuilds.daemonPIDs()
        var finished: [BuildRecord] = []
        var running: GradleBuilds.Running?
        for log in GradleBuilds.daemonLogs(since: Date().addingTimeInterval(-14 * 86400)) {
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { continue }
            let alive = GradleBuilds.pid(ofLog: log).map { pids.contains($0) } ?? false
            let scan = GradleBuilds.scan(log: text, file: log.lastPathComponent, daemonAlive: alive)
            finished += scan.finished
            if let candidate = scan.running, candidate.started > (running?.started ?? .distantPast) { running = candidate }
        }
        finished.sort { $0.finished > $1.finished }
        let current = running.map { run in
            let same = finished.filter { $0.name == run.name }.map(\.duration)
            return CurrentBuild(target: run.name, detail: "Gradle", startedAt: run.started,
                                averageDuration: same.isEmpty ? nil : same.reduce(0, +) / Double(same.count),
                                step: L10n.string("Gradle daemon busy"))
        }
        return (current, finished, pids.count)
    }

    // MARK: - Caches

    var cacheURL: URL { platform == .xcode ? XcodeBuilds.derivedData : GradleBuilds.caches }

    func measureSizesIfStale() {
        let target = platform
        if let measured = sizesMeasured[target], Date().timeIntervalSince(measured) < 300 { return }
        sizeTask?.cancel()
        let url = cacheURL
        sizeTask = Task { [weak self] in
            let bytes = await FolderSize.of(url)
            guard let self, !Task.isCancelled else { return }
            cacheBytes[target] = bytes
            sizesMeasured[target] = Date()
        }
    }

    func revealCache() {
        NSWorkspace.shared.activateFileViewerSelecting([cacheURL])
    }

    func clearDerivedData() {
        confirmingClear = false
        isClearing = true
        Task { [weak self] in
            _ = await XcodeBuilds.clear()
            guard let self else { return }
            isClearing = false
            sizesMeasured[.xcode] = nil
            measureSizesIfStale()
        }
    }

    func stopDaemons() {
        Task { [weak self] in
            let stopped = await Task.detached { GradleBuilds.stopDaemons() }.value
            Log.app.info("asked \(stopped, privacy: .public) Gradle daemon(s) to stop")
            await self?.poll()
        }
    }
}

/// Remembers when a build was first seen running, so the timer keeps counting
/// across polls instead of restarting at each sample.
final class BuildClock: @unchecked Sendable {
    // Guarded by `lock`; the only mutable state reachable from several tasks.
    static let shared = BuildClock()
    private let lock = NSLock()
    private var starts: [String: Date] = [:]
    private var lastSeen: [String: Date] = [:]

    func start(for key: String) -> Date {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        // A gap of more than 20 s means the previous build ended.
        if let seen = lastSeen[key], now.timeIntervalSince(seen) > 20 { starts[key] = nil }
        lastSeen[key] = now
        if let start = starts[key] { return start }
        starts[key] = now
        return now
    }
}
