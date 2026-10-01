import AppKit
import SwiftUI

/// The island on one display: window, host view, hover tracking, and the
/// open/close and keyboard mechanics. All screens share one `HubModel`.
@MainActor
final class IslandScreen: NSObject, NSWindowDelegate {
    let metrics: ScreenMetrics
    let session: ScreenSession
    /// Raised when anything the coordinator aggregates across screens moves.
    var onStateChange: (() -> Void)?

    private let model: HubModel
    private let window: IslandWindow
    private let host: IslandHostView
    private var tracker: HoverTracker!
    /// Any newer open/close outdates the deferred half of an older collapse.
    private var generation = 0
    /// Matches the close spring: key status and the click area are left
    /// alone until the shape has finished folding.
    private static let collapseDuration: Duration = HubTheme.Motion.closeSettle

    init(metrics: ScreenMetrics, model: HubModel) {
        self.metrics = metrics
        self.model = model
        self.session = ScreenSession(metrics: metrics, model: model)
        self.window = IslandWindow(frame: metrics.windowFrame)
        self.host = IslandHostView(frame: CGRect(origin: .zero, size: metrics.windowSize))
        super.init()
        tracker = HoverTracker { [weak self] in self?.regions() }
        build()
    }

    func teardown() {
        tracker.stop()
        generation += 1
        window.allowsTyping = false
        window.delegate = nil
        window.orderOut(nil)
        window.contentView = nil
    }

    func setFrame(_ frame: CGRect) {
        window.setFrame(frame, display: false)
    }

    // MARK: - External events

    /// Opened by the menu bar or a shortcut, with the pointer elsewhere. The
    /// pointer rule — open while it is on the island — would fold it at once,
    /// so it is held open until the pointer has visited and left, the
    /// keyboard is handed back (Esc), or a click lands in another app.
    private var heldOpen = false

    func toggle() {
        if session.isOpen { collapse() } else { open(on: nil) }
    }

    func open(on section: Section?) {
        if let section { session.select(section) }
        heldOpen = true
        setOpen(true)
        tracker.force(inside: true)
    }

    func collapse() {
        heldOpen = false
        guard session.isOpen else { return }
        setOpen(false)
        tracker.force(inside: false)
    }

    /// A few seconds of news on the closed notch.
    func showFlash(_ flash: NotchFlash) {
        guard !session.isOpen else { return }
        session.flash = flash
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.session.flash == flash else { return }
            self.session.flash = nil
        }
    }

    func screensSlept() {
        collapse()
        tracker.stop()
    }

    func screensWoke() {
        tracker.start()
    }

    func sectionDidChange(_ section: Section) {
        if !section.needsKeyboard { session.wantsKeyboard = false }
        if session.isOpen { refreshActiveRect() }
    }

    // MARK: - Construction

    private func build() {
        host.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: IslandRootView(model: model, session: session))
        hosting.sizingOptions = []
        hosting.frame = host.bounds
        hosting.autoresizingMask = [.width, .height]
        host.addSubview(hosting)
        window.contentView = host
        window.delegate = self
        window.ignoresMouseEvents = true

        host.dropHandlers = IslandHostView.DropHandlers(
            began: { [weak self] in
                guard let self, model.isVisible(.stash) else { return }
                session.select(.stash)
                session.isDropTarget = true
                setOpen(true)
            },
            cancelled: { [weak self] in self?.session.isDropTarget = false },
            delivered: { [weak self] urls in
                guard let self else { return false }
                session.isDropTarget = false
                return model.accept(urls: urls)
            }
        )
        window.onMouseDown = { [weak self] in
            guard let self else { return }
            // With hover-to-open off, a click on the closed notch opens it.
            if !session.isOpen {
                setOpen(true)
                tracker.force(inside: true)
                return
            }
            if model.clickTakesKeyboard { session.wantsKeyboard = true }
        }
        session.onChange = { [weak self] change in
            self?.sessionChanged(change)
        }
        tracker.onDecision = { [weak self] decision in
            guard let self else { return }
            if decision == .open, !model.preferences.values.general.openOnHover { return }
            setOpen(decision == .open)
        }
        tracker.onInteractiveChange = { [weak self] interactive in
            self?.window.ignoresMouseEvents = !interactive
        }
        tracker.onOptionChange = { [weak self] held in
            guard let self else { return }
            model.showsTabKeys = held && session.isOpen && !session.wantsKeyboard
        }

        refreshActiveRect()
        window.orderFrontRegardless()
        tracker.start()
    }

    private func regions() -> HoverTracker.Regions {
        let current = session.isActive ? session.openBodySize : metrics.collapsedSize
        let close = metrics.closeRect(open: session.openBodySize)
        // Once the pointer arrives, the island obeys it again.
        if heldOpen, close.contains(NSEvent.mouseLocation) { heldOpen = false }
        return .init(
            open: metrics.openRect,
            close: close,
            interactive: interactiveRect(current),
            warm: metrics.warmZone,
            isOpen: session.isActive,
            // Incoming file drop, or cards being dragged out of the stash.
            holding: heldOpen || host.dropInProgress || model.stash.isDraggingOut,
            openDelay: metrics.openDelay,
            closeDelay: metrics.closeDelay
        )
    }

    // MARK: - Open / close

    /// Opening grows the clickable area *before* the animation, so the pointer
    /// never falls through a part already drawn. Closing shrinks it and gives
    /// the keyboard back only *after* the animation — releasing key status
    /// mid-animation drops the repaint and strands an expanded picture.
    private func setOpen(_ open: Bool) {
        guard session.isOpen != open else { return }
        generation += 1
        Log.island.debug("display \(self.metrics.displayID, privacy: .public) \(open ? "open" : "close", privacy: .public)")
        if open {
            host.hotArea = metrics.toWindow(metrics.interactiveRect(session.openBodySize))
            session.flash = nil
            session.isOpen = true
            if model.preferences.values.general.haptics { Haptics.tick() }
        } else {
            heldOpen = false
            session.isOpen = false
            session.wantsKeyboard = false
            let expected = generation
            Task { [weak self] in
                try? await Task.sleep(for: Self.collapseDuration)
                guard let self, self.generation == expected else { return }
                self.refreshActiveRect()
                self.window.dropKeyboard()
            }
        }
    }

    private func refreshActiveRect() {
        let size = session.isActive ? session.openBodySize : metrics.collapsedSize
        let rect = interactiveRect(size)
        host.hotArea = rect.isEmpty ? .zero : metrics.toWindow(rect)
    }

    private func interactiveRect(_ size: CGSize) -> CGRect {
        metrics.interactiveRect(size)
    }

    private func sessionChanged(_ change: ScreenSession.Change) {
        if change == .keyboard {
            window.allowsTyping = session.wantsKeyboard
            // While collapsing, the deferred half of `setOpen` releases it.
            if !session.wantsKeyboard, session.isOpen { window.dropKeyboard() }
            // Esc on an island opened by shortcut: give it back to the pointer.
            if !session.wantsKeyboard { heldOpen = false }
        }
        if change == .dropTarget, !session.isDropTarget, session.isOpen {
            refreshActiveRect()
        }
        onStateChange?()
    }

    // MARK: - NSWindowDelegate

    /// A click into another app takes the keyboard away without touching the
    /// section — what was typed stays, and the island is free to collapse.
    func windowDidResignKey(_ notification: Notification) {
        session.wantsKeyboard = false
    }
}
