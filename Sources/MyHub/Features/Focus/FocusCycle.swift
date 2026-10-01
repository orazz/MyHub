import Foundation

/// The Pomodoro cycle as a value: focus, short break, focus … long break,
/// then round 1 again.
///
/// Pure — every method takes `now` — so the whole cycle is unit-tested
/// without waiting. `FocusStore` holds one, saves it, and wakes up at
/// `endsAt` to call `finish`.
struct FocusCycle: Codable, Equatable, Sendable {
    enum Phase: String, Codable, CaseIterable, Sendable {
        case work, shortBreak, longBreak

        var isBreak: Bool { self != .work }

        var title: String {
            switch self {
            case .work: L10n.string("Focus")
            case .shortBreak: L10n.string("Short break")
            case .longBreak: L10n.string("Long break")
            }
        }

        var shortTitle: String {
            switch self {
            case .work: L10n.string("Focus")
            case .shortBreak: L10n.string("Short")
            case .longBreak: L10n.string("Long")
            }
        }
    }

    struct Lengths: Equatable, Sendable {
        var work: TimeInterval
        var shortBreak: TimeInterval
        var longBreak: TimeInterval
        var rounds: Int

        init(_ prefs: Preferences.Focus) {
            work = TimeInterval(max(1, prefs.workMinutes) * 60)
            shortBreak = TimeInterval(max(1, prefs.shortBreakMinutes) * 60)
            longBreak = TimeInterval(max(1, prefs.longBreakMinutes) * 60)
            rounds = max(1, prefs.rounds)
        }

        init(work: TimeInterval, shortBreak: TimeInterval, longBreak: TimeInterval, rounds: Int) {
            self.work = work
            self.shortBreak = shortBreak
            self.longBreak = longBreak
            self.rounds = rounds
        }

        func length(of phase: Phase) -> TimeInterval {
            switch phase {
            case .work: work
            case .shortBreak: shortBreak
            case .longBreak: longBreak
            }
        }
    }

    private(set) var phase: Phase = .work
    /// Focus rounds finished in the current cycle (0…rounds). Reaches
    /// `rounds` during the long break, back to 0 when it ends.
    private(set) var completedRounds = 0
    /// Focus rounds finished today, and the time spent in them.
    private(set) var roundsToday = 0
    private(set) var focusedToday: TimeInterval = 0
    private(set) var day: Date?
    /// Set while running.
    private(set) var endsAt: Date?
    /// Set while paused: what was left.
    private(set) var pausedRemaining: TimeInterval?

    var isRunning: Bool { endsAt != nil }
    var isPaused: Bool { pausedRemaining != nil }
    /// At the start of a phase, not yet started.
    var isIdle: Bool { !isRunning && !isPaused }

    func remaining(at now: Date, lengths: Lengths) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return pausedRemaining ?? lengths.length(of: phase)
    }

    /// 0…1 through the current phase.
    func progress(at now: Date, lengths: Lengths) -> Double {
        let total = lengths.length(of: phase)
        return total > 0 ? min(1, max(0, 1 - remaining(at: now, lengths: lengths) / total)) : 0
    }

    /// "Round 2 of 4": the focus round under way, or the one just finished
    /// during its break.
    func round(lengths: Lengths) -> Int {
        let current = phase == .work ? completedRounds + 1 : completedRounds
        return min(max(1, current), lengths.rounds)
    }

    /// Fill of each round bar: 1 for done, the live share for the focus
    /// round under way, 0 for the rest.
    func roundFills(at now: Date, lengths: Lengths) -> [Double] {
        (0..<lengths.rounds).map { index in
            if index < completedRounds { return 1 }
            if index == completedRounds, phase == .work { return progress(at: now, lengths: lengths) }
            return 0
        }
    }

    // MARK: - Controls

    mutating func start(at now: Date, lengths: Lengths) {
        rollDay(now)
        endsAt = now.addingTimeInterval(pausedRemaining ?? lengths.length(of: phase))
        pausedRemaining = nil
    }

    mutating func pause(at now: Date) {
        guard let endsAt else { return }
        pausedRemaining = max(0, endsAt.timeIntervalSince(now))
        self.endsAt = nil
    }

    /// Jump to `phase` at its full length, paused.
    mutating func select(_ phase: Phase) {
        self.phase = phase
        endsAt = nil
        pausedRemaining = nil
    }

    /// Back to the first focus round; today's totals stay.
    mutating func reset() {
        phase = .work
        completedRounds = 0
        endsAt = nil
        pausedRemaining = nil
    }

    /// The current phase ended — its time ran out, or it was skipped — and
    /// the next one begins. A finished focus round counts (with the time
    /// actually spent); after the last one comes the long break; after the
    /// long break, round 1. The next phase runs straight away when this one
    /// was running or ran out; a skip from a stopped timer leaves it stopped.
    /// Returns the phase that ended.
    @discardableResult
    mutating func finish(at now: Date, lengths: Lengths) -> Phase {
        rollDay(now)
        let ended = phase
        let wasRunning = isRunning
        if ended == .work {
            let spent = lengths.work - remaining(at: now, lengths: lengths)
            completedRounds = min(completedRounds + 1, lengths.rounds)
            roundsToday += 1
            focusedToday += max(0, spent)
            phase = completedRounds >= lengths.rounds ? .longBreak : .shortBreak
        } else {
            if ended == .longBreak { completedRounds = 0 }
            phase = .work
        }
        pausedRemaining = nil
        endsAt = wasRunning ? now.addingTimeInterval(lengths.length(of: phase)) : nil
        return ended
    }

    /// Whether the running phase is over at `now` (MyHub may have been asleep
    /// or quit through the end).
    func isDue(at now: Date) -> Bool {
        endsAt.map { $0 <= now } ?? false
    }

    /// Today's figures start again after local midnight.
    private mutating func rollDay(_ now: Date) {
        if let day, Calendar.current.isDate(day, inSameDayAs: now) { return }
        day = now
        roundsToday = 0
        focusedToday = 0
    }

    /// Today's figures as of `now` (zero if the last activity was earlier).
    func today(at now: Date) -> (rounds: Int, focused: TimeInterval) {
        guard let day, Calendar.current.isDate(day, inSameDayAs: now) else { return (0, 0) }
        return (roundsToday, focusedToday)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "25m", "1h 15m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
