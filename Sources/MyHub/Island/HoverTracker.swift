import AppKit

/// Feeds the pointer position to a `HoverMachine` and reports what it decides.
///
/// MyHub reads `NSEvent.mouseLocation` on a clock instead of subscribing to
/// mouse events. Event monitors split the world in two — one kind is blind to
/// MyHub's own windows, the other only works while MyHub is the active app,
/// and a menu-bar utility is practically never that. Reading the position
/// works the same whatever is underneath.
///
/// Two speeds keep that cheap: a brisk rate while the pointer is moving
/// inside the island's warm zone (or the island is open), a lazy one the rest
/// of the time. A pointer resting in the warm zone drops to the lazy rate too.
@MainActor
final class HoverTracker {
    struct Regions {
        var open: CGRect
        var close: CGRect
        var interactive: CGRect
        var warm: CGRect
        var isOpen: Bool
        var holding: Bool
        var openDelay: TimeInterval
        var closeDelay: TimeInterval
    }

    var regions: () -> Regions?
    var onDecision: (HoverMachine.Decision) -> Void = { _ in }
    var onInteractiveChange: (Bool) -> Void = { _ in }
    /// Whether ⌥ alone is held, sampled with the pointer while the island is
    /// open (`NSEvent.modifierFlags` is the system-wide state; no key events
    /// or permissions involved).
    var onOptionChange: (Bool) -> Void = { _ in }
    private var reportedOption = false

    private var machine = HoverMachine()
    private let clock = Ticker()
    private var brisk: Bool { clock.period == Rate.brisk }
    /// Where the pointer was at the previous sample; nil before the first.
    private var previousPoint: CGPoint?
    private var movedAt = Date.distantPast
    /// What `onInteractiveChange` last reported; nil means "say it again".
    private var reportedInteractive: Bool?

    private enum Rate {
        static let brisk: TimeInterval = 1.0 / 60
        static let lazy: TimeInterval = 1.0 / 8
        /// Still for this long counts as resting.
        static let restAfter: TimeInterval = 3
        /// How far past the warm zone the brisk rate holds before dropping.
        static let hysteresis: CGFloat = 80
    }

    init(regions: @escaping () -> Regions?) {
        self.regions = regions
    }

    func start() {
        setRate(Rate.lazy)
    }

    func stop() {
        clock.halt()
        // The window built next begins click-through; forget what was
        // reported so the first sample tells it again.
        reportedInteractive = nil
    }

    func force(inside: Bool) {
        machine.force(inside: inside)
    }

    /// Dwell is timed on the brisk clock, so it gets little slack; the lazy
    /// clock only has to notice an approach and may be batched freely.
    private func setRate(_ period: TimeInterval) {
        clock.run(every: period, slack: period == Rate.brisk ? 0.25 : 0.5) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard let regions = regions() else { return }
        let point = NSEvent.mouseLocation
        let now = Date()
        adjustRate(point: point, now: now, regions: regions)

        let option = regions.isOpen && NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]) == .option
        if option != reportedOption {
            reportedOption = option
            onOptionChange(option)
        }

        let interactive = regions.holding || regions.interactive.contains(point)
        if reportedInteractive != interactive {
            reportedInteractive = interactive
            onInteractiveChange(interactive)
        }

        let decision = machine.step(.init(
            point: point, now: now,
            openRect: regions.open, closeRect: regions.close,
            isOpen: regions.isOpen, holding: regions.holding,
            openDelay: regions.openDelay, closeDelay: regions.closeDelay
        ))
        if decision != .none { onDecision(decision) }
    }

    private func adjustRate(point: CGPoint, now: Date, regions: Regions) {
        if previousPoint != point {
            previousPoint = point
            movedAt = now
        }
        let resting = now.timeIntervalSince(movedAt) >= Rate.restAfter
        // Once brisk, stay brisk until the pointer is clearly away from the
        // warm zone, so wobbling on its border does not flip the rate.
        let zone = brisk ? regions.warm.insetBy(dx: -Rate.hysteresis, dy: -Rate.hysteresis) : regions.warm
        let engaged = regions.isOpen || machine.pointerInside || zone.contains(point)
        let wanted = engaged && !resting ? Rate.brisk : Rate.lazy
        if wanted != clock.period { setRate(wanted) }
    }
}
