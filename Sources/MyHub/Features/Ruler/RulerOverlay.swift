import AppKit
@preconcurrency import ScreenCaptureKit

/// The screen ruler: a transparent overlay on every display.
///
/// - Move: crosshair with the pointer's position.
/// - Drag: a rectangle with its size in points (and pixels on Retina).
/// - With the loupe on: an 11×11-pixel magnifier and the colour under the
///   pointer.
/// - C copies the size, or the colour when nothing is measured; L turns the
///   loupe on; Esc or a right-click closes.
///
/// The loupe reads a single screenshot taken just before the overlay
/// appears, which needs Screen Recording permission. It is never asked for at
/// launch — only when L is pressed — and the ruler works without it.
@MainActor
final class RulerController {
    private var panels: [RulerPanel] = []
    var isActive: Bool { !panels.isEmpty }

    func toggle() {
        if isActive { close() } else { Task { await open() } }
    }

    func open() async {
        guard !isActive else { return }
        let captures = CGPreflightScreenCaptureAccess() ? await Self.captureScreens() : [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let panel = RulerPanel(screen: screen, capture: captures[id], controller: self)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        // Keys go to the panel under the pointer.
        let mouse = NSEvent.mouseLocation
        (panels.first { $0.frame.contains(mouse) } ?? panels.first)?.makeKey()
        NSCursor.crosshair.push()
    }

    func close() {
        guard isActive else { return }
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        NSCursor.pop()
    }

    /// L: ask for Screen Recording (the system shows its prompt once), then
    /// reopen with screenshots if it was granted.
    func enableLoupe() {
        if CGPreflightScreenCaptureAccess() {
            close()
            Task { await open() }
        } else {
            CGRequestScreenCaptureAccess()
        }
    }

    /// One still per display, captured before the overlay is up so the
    /// overlay isn't in it.
    private static func captureScreens() async -> [CGDirectDisplayID: CGImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [:] }
        var images: [CGDirectDisplayID: CGImage] = [:]
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                images[display.displayID] = image
            }
        }
        return images
    }
}

/// A borderless panel covering one display. Non-activating, like the
/// island: it takes keys (Esc, C, L) without bringing MyHub forward.
private final class RulerPanel: NSPanel {
    init(screen: NSScreen, capture: CGImage?, controller: RulerController) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        setFrame(screen.frame, display: false)
        contentView = RulerView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                scale: screen.backingScaleFactor, capture: capture, controller: controller)
    }

    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class RulerView: NSView {
    private let scale: CGFloat
    private let capture: CGImage?
    private weak var controller: RulerController?
    private var pointer: CGPoint?
    private var dragStart: CGPoint?
    private var measured: CGRect?
    private var copiedNote: String?

    init(frame: CGRect, scale: CGFloat, capture: CGImage?, controller: RulerController) {
        self.scale = scale
        self.capture = capture
        self.controller = controller
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Input

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        window?.makeKey()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        measured = nil
        pointer = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        if let dragStart, let pointer { measured = RulerGeometry.rect(from: dragStart, to: pointer) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        if let measured, measured.width < 2, measured.height < 2 { self.measured = nil }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) { controller?.close() }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "\u{1b}": controller?.close()
        case "c": copyReading()
        case "l": controller?.enableLoupe()
        default:
            if event.keyCode == 53 { controller?.close() } else { super.keyDown(with: event) }
        }
    }

    override func cancelOperation(_ sender: Any?) { controller?.close() }

    private func copyReading() {
        let text: String
        if let measured {
            text = RulerGeometry.copyText(for: measured)
        } else if let pointer, let color = color(at: pointer) {
            text = color
        } else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedNote = L10n.format("Copied %@", text)
        needsDisplay = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.copiedNote = nil
            self?.needsDisplay = true
        }
    }

    // MARK: Pixels

    private func color(at point: CGPoint) -> String? {
        guard let capture else { return nil }
        let pixel = RulerGeometry.pixel(for: point, viewHeight: bounds.height, scale: scale)
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < capture.width, pixel.y < capture.height,
              let one = capture.cropping(to: CGRect(x: pixel.x, y: pixel.y, width: 1, height: 1)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RulerGeometry.hex(red: rgba[0], green: rgba[1], blue: rgba[2])
    }

    // MARK: Drawing

    private let accent = NSColor(srgbRed: 0.91, green: 0.66, blue: 0.29, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.08).setFill()
        bounds.fill()

        if let measured {
            accent.withAlphaComponent(0.16).setFill()
            measured.fill()
            accent.setStroke()
            let path = NSBezierPath(rect: measured.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
            let anchor = CGPoint(x: measured.maxX, y: measured.minY)
            drawBubble(RulerGeometry.label(for: measured, scale: scale), near: anchor)
        }

        if let pointer {
            accent.withAlphaComponent(0.7).setStroke()
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: bounds.minX, y: pointer.y.rounded() + 0.5))
            cross.line(to: CGPoint(x: bounds.maxX, y: pointer.y.rounded() + 0.5))
            cross.move(to: CGPoint(x: pointer.x.rounded() + 0.5, y: bounds.minY))
            cross.line(to: CGPoint(x: pointer.x.rounded() + 0.5, y: bounds.maxY))
            cross.lineWidth = 1
            cross.stroke()
            if measured == nil || dragStart != nil {
                if capture != nil, dragStart == nil {
                    drawLoupe(at: pointer)
                } else if dragStart == nil {
                    let x = Int(pointer.x.rounded()), y = Int((bounds.height - pointer.y).rounded())
                    drawBubble("\(x), \(y)", near: pointer)
                }
            }
        }

        let hint = copiedNote ?? (capture == nil
            ? L10n.string("Drag to measure · C copy · L colour loupe · Esc close")
            : L10n.string("Drag to measure · C copy size or colour · Esc close"))
        drawBubble(hint, at: CGPoint(x: bounds.midX, y: bounds.minY + 40), centered: true)
    }

    private func drawLoupe(at point: CGPoint) {
        guard let capture else { return }
        let pixel = RulerGeometry.pixel(for: point, viewHeight: bounds.height, scale: scale)
        let radius = 5
        let region = RulerGeometry.loupeRegion(around: pixel, radius: radius, imageSize: (capture.width, capture.height))
        guard let crop = capture.cropping(to: region), let context = NSGraphicsContext.current?.cgContext else { return }
        let side: CGFloat = 132
        let box = CGRect(origin: RulerGeometry.labelOrigin(near: point, size: CGSize(width: side, height: side + 26), bounds: bounds), size: CGSize(width: side, height: side + 26))
        let lens = CGRect(x: box.minX, y: box.minY + 26, width: side, height: side)

        context.saveGState()
        let rounded = CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.addPath(rounded)
        context.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        context.fillPath()
        context.addPath(CGPath(roundedRect: lens, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.clip()
        context.interpolationQuality = .none
        context.draw(crop, in: lens)
        context.restoreGState()

        // The centre pixel, outlined.
        let cell = side / CGFloat(radius * 2 + 1)
        let column = CGFloat(pixel.x - Int(region.minX)), row = CGFloat(pixel.y - Int(region.minY))
        let centre = CGRect(x: lens.minX + column * cell, y: lens.maxY - (row + 1) * cell, width: cell, height: cell)
        NSColor.white.setStroke()
        NSBezierPath(rect: centre).stroke()

        let text = color(at: point) ?? ""
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: box.midX - size.width / 2, y: box.minY + (26 - size.height) / 2), withAttributes: attributes)
    }

    private func drawBubble(_ text: String, near point: CGPoint) {
        let attributes = bubbleAttributes
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGSize(width: size.width + 16, height: size.height + 8)
        drawBubble(text, at: RulerGeometry.labelOrigin(near: point, size: box, bounds: bounds), centered: false)
    }

    private var bubbleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
    }

    private func drawBubble(_ text: String, at origin: CGPoint, centered: Bool) {
        let size = (text as NSString).size(withAttributes: bubbleAttributes)
        var box = CGRect(origin: origin, size: CGSize(width: size.width + 16, height: size.height + 8))
        if centered { box.origin.x -= box.width / 2 }
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: bubbleAttributes)
    }
}
