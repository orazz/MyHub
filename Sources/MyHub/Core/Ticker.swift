import Foundation

/// A repeating callback on the main run loop, used by everything in MyHub that
/// polls: the pointer, the pasteboard, the agenda's clock.
///
/// Registered in `.common` modes so it keeps firing while a menu is tracking
/// or a scroll view is being dragged. `slack` is the fraction of the period the
/// system may shift a fire by to batch wake-ups with other work — high for
/// background polling, low where timing is visible.
@MainActor
final class Ticker {
    private var timer: Timer?
    private(set) var period: TimeInterval = 0

    var isRunning: Bool { timer != nil }

    /// Starts ticking, or switches an already running ticker to a new period.
    func run(every period: TimeInterval, slack: Double = 0.25, _ tick: @escaping @MainActor @Sendable () -> Void) {
        halt()
        self.period = period
        let timer = Timer(timeInterval: period, repeats: true) { _ in
            MainActor.assumeIsolated(tick)
        }
        timer.tolerance = period * slack
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func halt() {
        timer?.invalidate()
        timer = nil
    }
}
