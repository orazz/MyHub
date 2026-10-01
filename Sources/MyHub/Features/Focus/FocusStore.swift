import AppKit
import Observation

/// Runs the Pomodoro cycle.
///
/// No clock ticks to keep time: the store sleeps until the phase's end date
/// and wakes once. The countdown on screen is drawn by a `TimelineView`, which
/// only runs while it is visible. The cycle is saved, so a round survives a
/// relaunch (and one that ended meanwhile is wrapped up at launch).
///
/// Do Not Disturb: macOS has no API to switch a Focus mode, but Shortcuts
/// does. The user names a shortcut to run when a round starts and one for
/// when it ends; MyHub runs them with `/usr/bin/shortcuts`.
@MainActor
@Observable
final class FocusStore {
    private(set) var cycle: FocusCycle
    private(set) var shortcutNames: [String] = []
    private(set) var shortcutProblem: String?
    /// Timer settings instead of the timer.
    var showingSettings = false

    /// A phase ended: the coordinator flashes the notch.
    @ObservationIgnored var onPhaseEnded: ((FocusCycle.Phase, FocusCycle.Phase) -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var wake: Task<Void, Never>?

    init(preferences: Preferences, file: URL = AppPaths.file("focus.json")) {
        self.preferences = preferences
        self.file = file
        cycle = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(FocusCycle.self, from: $0) } ?? FocusCycle()
    }

    var lengths: FocusCycle.Lengths { FocusCycle.Lengths(preferences.values.focus) }
    var settings: Preferences.Focus { preferences.values.focus }

    /// Whether the closed notch shows the countdown.
    var showsInNotch: Bool { cycle.isRunning && settings.showInNotch }

    // MARK: - Lifecycle

    func start() {
        if cycle.isDue(at: Date()) { phaseEnded() } else { scheduleWake() }
    }

    func stop() {
        wake?.cancel()
        wake = nil
    }

    // MARK: - Controls

    /// Start, pause or resume.
    func startOrPause() {
        let now = Date()
        if cycle.isRunning {
            cycle.pause(at: now)
            if cycle.phase == .work { focusEnded() }
        } else {
            cycle.start(at: now, lengths: lengths)
            if cycle.phase == .work { focusBegan() }
        }
        changed()
    }

    /// The phase switch: load `phase` at full length, paused.
    func select(_ phase: FocusCycle.Phase) {
        if cycle.isRunning, cycle.phase == .work { focusEnded() }
        cycle.select(phase)
        changed()
    }

    func reset() {
        if cycle.isRunning, cycle.phase == .work { focusEnded() }
        cycle.reset()
        changed()
    }

    /// Straight to the next phase; a focus round counts as done.
    func skip() {
        phaseEnded(announce: false)
    }

    func update(_ change: (inout Preferences.Focus) -> Void) {
        preferences.update { change(&$0.focus) }
    }

    // MARK: - Phase changes

    private func phaseEnded(announce: Bool = true) {
        let wasRunningFocus = cycle.isRunning && cycle.phase == .work
        let ended = cycle.finish(at: Date(), lengths: lengths)
        if wasRunningFocus { focusEnded() }
        if cycle.isRunning, cycle.phase == .work { focusBegan() }
        if announce {
            if settings.chime { NSSound(named: ended == .work ? "Glass" : "Hero")?.play() }
            onPhaseEnded?(ended, cycle.phase)
        }
        changed()
    }

    /// Do Not Disturb: the user's Shortcuts, when the switch is on.
    private func focusBegan() {
        if settings.doNotDisturb { runShortcut(settings.startShortcut) }
    }

    private func focusEnded() {
        if settings.doNotDisturb { runShortcut(settings.endShortcut) }
    }

    private func changed() {
        save()
        scheduleWake()
    }

    private func scheduleWake() {
        wake?.cancel()
        wake = nil
        guard let endsAt = cycle.endsAt else { return }
        wake = Task { [weak self] in
            let delay = max(0, endsAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(500))
            guard !Task.isCancelled, let self, cycle.isDue(at: Date()) else { return }
            phaseEnded()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cycle) else { return }
        try? AppPaths.writePrivate(data, to: file)
    }

    // MARK: - Shortcuts

    /// Names from `shortcuts list`, for the pickers. Read when the Focus
    /// settings are opened, not at launch.
    func loadShortcutNames() {
        Task { [weak self] in
            let out = try? await CommandRunner.run("/usr/bin/shortcuts", ["list"], timeout: .seconds(10))
            guard let self else { return }
            if let out, out.succeeded {
                shortcutNames = out.stdout.split(whereSeparator: \.isNewline).map(String.init).sorted()
            }
        }
    }

    private func runShortcut(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { [weak self] in
            let out = try? await CommandRunner.run("/usr/bin/shortcuts", ["run", trimmed], timeout: .seconds(30))
            self?.shortcutProblem = out?.succeeded == true ? nil : L10n.format("Shortcut “%@” failed", trimmed)
        }
    }

    #if DEBUG
    func injectForPreview(_ cycle: FocusCycle) { self.cycle = cycle }
    #endif
}
