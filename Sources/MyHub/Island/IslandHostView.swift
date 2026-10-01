import AppKit

/// Root AppKit view of an island window.
///
/// Three jobs: it answers hit-tests only inside the region the island
/// currently occupies (`hotArea`), keeps the arrow cursor there, and accepts
/// file drops. Everything visible is drawn by the SwiftUI host inside it.
final class IslandHostView: NSView {
    /// Callbacks for an incoming file drop.
    struct DropHandlers {
        var began: () -> Void = {}
        var cancelled: () -> Void = {}
        var delivered: ([URL]) -> Bool = { _ in false }
    }

    var dropHandlers = DropHandlers()

    /// The part of the window the island occupies right now, in this view's
    /// coordinates. Outside it the view does not exist as far as the mouse is
    /// concerned.
    var hotArea: CGRect = .zero {
        didSet {
            if hotArea != oldValue { rebuildArrowRegion() }
        }
    }

    /// True from a drag entering until it leaves or drops. The whole view
    /// stays a target meanwhile, even outside `hotArea`, so the drag is not
    /// lost while the island grows under the pointer.
    private(set) var dropInProgress = false

    private var arrowRegion: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }

    // MARK: Mouse

    /// MyHub never activates, so a first click has to count as a real click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Real click-through comes from `ignoresMouseEvents`, which the hover
    /// tracker flips; this only covers the gaps between its samples.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if dropInProgress || hotArea.contains(point) { return super.hitTest(point) }
        return nil
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildArrowRegion()
    }

    /// Without a claim of its own the island would show whatever cursor the
    /// app underneath asked for. Cursor rects only work in a key window, and
    /// this one rarely is, so an always-on tracking area does the job.
    private func rebuildArrowRegion() {
        arrowRegion.map(removeTrackingArea)
        arrowRegion = nil
        if hotArea.isEmpty { return }
        let region = NSTrackingArea(rect: hotArea, options: [.activeAlways, .cursorUpdate, .mouseEnteredAndExited], owner: self)
        addTrackingArea(region)
        arrowRegion = region
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }

    // MARK: Dropping files

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        if droppedFiles(info).isEmpty { return [] }
        dropInProgress = true
        dropHandlers.began()
        return .copy
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(info).isEmpty ? [] : .copy
    }

    override func draggingExited(_ info: NSDraggingInfo?) {
        dropInProgress = false
        dropHandlers.cancelled()
    }

    override func draggingEnded(_ info: NSDraggingInfo) {
        dropInProgress = false
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        dropInProgress = false
        let files = droppedFiles(info)
        return files.isEmpty ? false : dropHandlers.delivered(files)
    }
}
