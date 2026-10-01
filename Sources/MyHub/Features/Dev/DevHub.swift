import Observation

/// The Dev tab: four pages sharing one dock icon.
@MainActor
@Observable
final class DevHub {
    enum Page: String, CaseIterable, Sendable {
        case simulators, git, ci, cleanup

        var title: String {
            switch self {
            case .simulators: L10n.string("Simulators")
            case .git: "Git"
            case .ci: "CI"
            case .cleanup: L10n.string("Cleanup")
            }
        }
    }

    var page: Page = .simulators {
        didSet { if page != oldValue { pageShown() } }
    }

    let simulators = SimulatorStore()
    let repos: RepoStore
    let cleanup = CleanupStore()

    init(preferences: Preferences) {
        repos = RepoStore(preferences: preferences)
    }

    func start() { repos.start() }

    func stop() {
        repos.stop()
        simulators.stop()
    }

    #if DEBUG
    /// Snapshots only: keep injected sample data instead of reading the Mac.
    var frozen = false
    #endif

    /// The tab, or a page within it, came into view: read what it shows.
    func pageShown() {
        #if DEBUG
        if frozen { return }
        #endif
        switch page {
        case .simulators: simulators.refresh()
        case .git, .ci: repos.pageShown()
        case .cleanup: cleanup.pageShown()
        }
    }
}
