import CoreGraphics
import Foundation

/// Pure open/close decision logic for one island, fed a pointer sample at a
/// time. No timers, no AppKit — so every rule here is unit-tested.
///
/// The pointer is the single authority on whether the island is open. The
/// island can be opened by other means (menu bar, a drag), and whenever that
/// leaves it open with the pointer elsewhere, the next samples close it.
struct HoverMachine {
    enum Decision: Equatable { case none, open, close }

    struct Input {
        var point: CGPoint
        var now: Date
        var openRect: CGRect
        var closeRect: CGRect
        /// The island is open right now, for whatever reason.
        var isOpen: Bool
        /// Keep open regardless of the pointer (a drag in flight).
        var holding: Bool
        var openDelay: TimeInterval
        var closeDelay: TimeInterval
    }

    private(set) var pointerInside = false
    private var pendingSince: Date?

    /// Records a state change made elsewhere (menu bar toggle, sleep).
    mutating func force(inside: Bool) {
        pointerInside = inside
        pendingSince = nil
    }

    mutating func step(_ input: Input) -> Decision {
        let open = pointerInside || input.isOpen
        let region = open ? input.closeRect : input.openRect
        let wantsOpen = input.holding || region.contains(input.point)

        guard wantsOpen != open else {
            pointerInside = open
            pendingSince = nil
            return .none
        }
        guard let since = pendingSince else {
            pendingSince = input.now
            return .none
        }
        let delay = wantsOpen ? input.openDelay : input.closeDelay
        guard input.now.timeIntervalSince(since) >= delay else { return .none }
        pendingSince = nil
        pointerInside = wantsOpen
        return wantsOpen ? .open : .close
    }
}
