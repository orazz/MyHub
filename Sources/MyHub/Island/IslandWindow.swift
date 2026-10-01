import AppKit
import Carbon.HIToolbox

/// Borderless, non-activating panel one level above the menu bar, on every
/// space. It never resizes: only the SwiftUI content inside animates.
final class IslandWindow: NSPanel {
    /// Whether the island may take the keyboard. Normally not: a panel you
    /// merely hover over should never dim the window you are working in. A
    /// section with a text field turns it on; thanks to `.nonactivatingPanel`
    /// the island then receives keys while MyHub stays in the background.
    var allowsTyping = false {
        didSet { if allowsTyping && !oldValue { makeKey() } }
    }

    /// Any left click inside the island, before it is delivered. A gesture on
    /// a SwiftUI `TextEditor` never fires (the text view claims the click), so
    /// this is the reliable place to notice a click into a field.
    var onMouseDown: (() -> Void)?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        // Stacking. `isFloatingPanel` comes first because setting it also
        // sets `level` (to `.floating`, under the menu bar). If it came
        // second, AppKit would nudge the window down clear of the menu bar,
        // and the drawn island would sit below the region that takes clicks.
        isFloatingPanel = true
        level = Self.islandLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false

        // Look. A transparent canvas; SwiftUI draws the shape and its shadow.
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        animationBehavior = .none
        // Always dark, like the island itself, so AppKit text fields never
        // pick light-mode black text.
        appearance = NSAppearance(named: .darkAqua)

        // Behaviour.
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
    }

    /// One above the status bar, so the island covers the menu bar itself.
    static let islandLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)

    /// The frame is computed to sit flush with the top edge, over the menu
    /// bar. AppKit's default constraint would move it below the bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { allowsTyping }
    override var canBecomeMain: Bool { false }

    /// AppKit can only move key status *to* a window, never drop it into
    /// nothing. Taking the window off screen and putting it straight back
    /// clears it with no visible change. Only call this once the island has
    /// finished folding.
    func dropKeyboard() {
        if allowsTyping || !isKeyWindow { return }
        orderOut(nil)
        orderFrontRegardless()
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if let action = EditingShortcut.action(for: event), firstResponder?.tryToPerform(action, with: self) == true {
                return
            }
        case .leftMouseDown:
            onMouseDown?()
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// Text-editing shortcuts. They normally come from the Edit menu, which an
/// app without a menu bar doesn't have, so the window routes them itself.
/// Keys are matched by position (virtual key code), so ⌘C is still ⌘C on a
/// Cyrillic or Greek layout.
enum EditingShortcut {
    static func action(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shifted = flags.contains(.shift)
        guard flags.subtracting(.shift) == .command else { return nil }
        switch (Int(event.keyCode), shifted) {
        case (kVK_ANSI_A, false): return #selector(NSText.selectAll(_:))
        case (kVK_ANSI_X, false): return #selector(NSText.cut(_:))
        case (kVK_ANSI_C, false): return #selector(NSText.copy(_:))
        case (kVK_ANSI_V, false): return #selector(NSText.paste(_:))
        case (kVK_ANSI_Z, false): return Selector(("undo:"))
        case (kVK_ANSI_Z, true): return Selector(("redo:"))
        default: return nil
        }
    }
}
