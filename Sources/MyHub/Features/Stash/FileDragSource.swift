import AppKit
import SwiftUI

/// An AppKit mouse surface laid over a stash card: click (with modifiers),
/// double-click, right-click menu, hover, and dragging one or many files out.
///
/// SwiftUI's `onDrag` carries a single item provider; a group of files needs
/// an `NSDraggingSession` with one dragging item per file.
struct FileDragSource: NSViewRepresentable {
    var urls: () -> [URL]
    var image: NSImage
    var onClick: (NSEvent.ModifierFlags) -> Void
    var onDoubleClick: () -> Void
    var onHover: (Bool) -> Void
    var onDragChange: (Bool) -> Void
    var menu: () -> NSMenu

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.urls = urls
        view.image = image
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
        view.onDragChange = onDragChange
        view.menuProvider = menu
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var image = NSImage()
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onDragChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var mouseDownEvent: NSEvent?
    private var isDragging = false
    private static let dragThreshold: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2 { onDoubleClick() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !isDragging else { return }
        let start = down.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= Self.dragThreshold else { return }
        beginDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !isDragging, event.clickCount == 1 else { return }
        onClick(event.modifierFlags)
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    private func beginDrag(with event: NSEvent) {
        let files = urls()
        guard !files.isEmpty else { return }
        isDragging = true
        let items = files.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            // A small fan, so a group reads as a group under the pointer.
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(bounds.offsetBy(dx: offset, dy: -offset), contents: image)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Dropping a card back on the island would only re-add it.
        context == .withinApplication ? [] : [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragChange(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        mouseDownEvent = nil
        onDragChange(false)
    }
}

/// NSMenu items that run a closure, for context menus built in code.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
