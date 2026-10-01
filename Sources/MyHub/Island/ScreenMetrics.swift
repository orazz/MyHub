import AppKit

/// Settings → Panel size. A bigger panel shows *more*, not the same bigger:
/// text and controls keep their designed size and the content area grows, so
/// lists, tiles and agendas fit more before they scroll.
enum PanelSize: String, Codable, CaseIterable, Sendable {
    case compact, standard, large, extraLarge

    /// Default is the handoff's 600 × 300: 38 top padding + 200 content + 14
    /// gap + 34 dock + 14 bottom padding.
    var size: CGSize {
        switch self {
        case .compact: CGSize(width: 560, height: 280)
        case .standard: CGSize(width: 600, height: 300)
        case .large: CGSize(width: 680, height: 360)
        case .extraLarge: CGSize(width: 760, height: 420)
        }
    }

    var title: String {
        switch self {
        case .compact: L10n.string("Compact")
        case .standard: L10n.string("Default")
        case .large: L10n.string("Large")
        case .extraLarge: L10n.string("XL")
        }
    }
}

/// Settings → Position: which edge of the screen the island lives on. At the
/// top it hangs from the notch; on the left or right it is docked to that
/// edge at mid-height and slides out sideways — the same island, turned.
enum PanelPosition: String, Codable, CaseIterable, Sendable {
    case left, center, right

    var title: String {
        switch self {
        case .left: L10n.string("Left")
        case .center: L10n.string("Top")
        case .right: L10n.string("Right")
        }
    }

    var isSide: Bool { self != .center }
}

/// The geometry of one display's island, all in global screen coordinates
/// (origin bottom-left) unless a name says otherwise.
///
/// At the top, on a display with a camera housing, the collapsed island *is*
/// the hole; elsewhere we draw one — a thin strip along the edge it is docked
/// to (the top, or the middle of the left or right edge), reached by pushing
/// the pointer against that edge.
@MainActor
struct ScreenMetrics {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let hasCutout: Bool
    /// The hole, or the synthetic notch we pretend is there.
    let notch: CGSize
    let fullHeightDrawn: Bool
    /// The open panel, from Settings → Panel size (capped to the screen).
    let bodySize: CGSize
    let position: PanelPosition

    static let dockHeight: CGFloat = 34
    static let horizontalPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 14
    static let stackGap: CGFloat = 14
    /// Room around the body for the shoulders and the 50pt-blur shadow.
    static let sideMargin: CGFloat = 50
    static let bottomMargin: CGFloat = 70
    static let drawnStripDepth: CGFloat = 6
    /// Length of the strip on the left or right edge — a notch turned on its side.
    static let sideStripLength: CGFloat = 180
    /// Top padding when docked to a side: no notch to clear.
    static let sideTopPadding: CGFloat = 14

    init?(screen: NSScreen, fullHeightDrawn: Bool, panelSize: PanelSize = .standard, position: PanelPosition = .center) {
        guard let id = screen.displayID else { return nil }
        self.screen = screen
        self.displayID = id
        self.fullHeightDrawn = fullHeightDrawn
        self.position = position
        // Never wider or taller than the screen can hold.
        let wanted = panelSize.size
        self.bodySize = CGSize(
            width: min(wanted.width, screen.frame.width - 2 * Self.sideMargin),
            height: min(wanted.height, max(PanelSize.compact.size.height, screen.frame.height * 0.6))
        )
        // The camera housing is whatever lies between the two menu-bar areas
        // macOS reports either side of it.
        let inset = screen.safeAreaInsets.top
        if inset > 0, let leftEar = screen.auxiliaryTopLeftArea, let rightEar = screen.auxiliaryTopRightArea,
           rightEar.minX > leftEar.maxX {
            hasCutout = true
            notch = CGSize(width: rightEar.minX - leftEar.maxX, height: inset)
        } else {
            hasCutout = false
            notch = CGSize(width: 180, height: max(NSStatusBar.system.thickness, 24))
        }
    }

    /// The displays that get an island. A display that mirrors another shows
    /// the same pixels, so it gets none of its own — the original's island
    /// already appears there.
    static func current(_ prefs: Preferences.Values) -> [ScreenMetrics] {
        let screens = NSScreen.screens.filter { screen in
            guard let id = screen.displayID else { return false }
            return CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay
        }
        let chosen: [NSScreen]
        if prefs.showOnAllDisplays {
            chosen = screens
        } else if let withNotch = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            chosen = [withNotch]
        } else {
            chosen = Array(screens.prefix(1))
        }
        return chosen.compactMap {
            ScreenMetrics(screen: $0, fullHeightDrawn: prefs.fullHeightDrawnNotch,
                          panelSize: prefs.general.panelSize, position: prefs.general.panelPosition)
        }
    }

    func matches(_ other: ScreenMetrics) -> Bool {
        displayID == other.displayID && screen.frame == other.screen.frame
            && notch == other.notch && hasCutout == other.hasCutout
            && fullHeightDrawn == other.fullHeightDrawn && bodySize == other.bodySize && position == other.position
    }

    /// Under a real hole — the only case where the closed island *is* the
    /// notch, and nothing needs painting.
    var sitsOnNotch: Bool { position == .center && hasCutout }

    // MARK: - Sizes

    var collapsedSize: CGSize {
        switch position {
        case .center:
            if hasCutout || fullHeightDrawn { return notch }
            return CGSize(width: notch.width, height: Self.drawnStripDepth)
        case .left, .right:
            return CGSize(width: Self.drawnStripDepth, height: Self.sideStripLength)
        }
    }

    /// Space above the content: the notch at the top (never less than the
    /// handoff's 38); just padding when docked to a side.
    var topPadding: CGFloat {
        position.isSide ? Self.sideTopPadding : max(38, notch.height + 6)
    }

    /// What a tab gets: 200 at the default size at the top, more at larger
    /// sizes and at the sides.
    var contentHeight: CGFloat {
        bodySize.height - topPadding - Self.stackGap - Self.dockHeight - Self.bottomPadding
    }

    /// A pointer thrown at a real hole can open quickly; a thin drawn strip
    /// sits where the pointer passes on its way to the menu bar, so it waits.
    /// A side strip sits on an edge the pointer rarely rests against.
    var openDelay: TimeInterval {
        switch position {
        case .center: hasCutout ? 0.05 : 0.2
        case .left, .right: 0.15
        }
    }
    var closeDelay: TimeInterval { 0.06 }

    // MARK: - Window

    /// The body at its largest, with room around it for shoulders and shadow.
    /// Parts of it may lie beyond the screen edge the island is docked to;
    /// the window is borderless and never constrained, so that is fine.
    var windowFrame: CGRect {
        let flare = HubTheme.Radius.openTop
        return bodyRect(bodySize).insetBy(dx: -(Self.sideMargin + flare), dy: -(Self.bottomMargin + flare))
    }

    var windowSize: CGSize { windowFrame.size }

    func toWindow(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
    }

    // MARK: - Hit regions

    /// A body of `size` docked to the island's edge: hanging from the top
    /// centre, or against the left or right edge at mid-height.
    func bodyRect(_ size: CGSize) -> CGRect {
        let frame = screen.frame
        switch position {
        case .center:
            return CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
        case .left:
            return CGRect(x: frame.minX, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        case .right:
            return CGRect(x: frame.maxX - size.width, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        }
    }

    /// The rect grown past the docked edge, so a pointer pinned against the
    /// edge still counts as inside.
    func growingOut(_ rect: CGRect, by amount: CGFloat) -> CGRect {
        switch position {
        case .center: rect.growingUp(amount)
        case .left: rect.offsetBy(dx: -amount, dy: 0).union(rect)
        case .right: rect.offsetBy(dx: amount, dy: 0).union(rect)
        }
    }

    /// Entering this opens the island.
    var openRect: CGRect {
        let strip = bodyRect(collapsedSize)
        let widened = position.isSide ? strip.insetBy(dx: 0, dy: -8) : strip.insetBy(dx: -8, dy: 0)
        return growingOut(widened, by: 4)
    }

    /// Leaving this closes it: the open body plus a little slack on its open
    /// sides, so a pointer skimming the edge does not flicker it shut.
    func closeRect(open size: CGSize) -> CGRect {
        var rect = bodyRect(size)
        switch position {
        case .center:
            rect = rect.insetBy(dx: -12, dy: 0)
            rect.origin.y -= 12
            rect.size.height += 12
        case .left:
            rect = rect.insetBy(dx: 0, dy: -12)
            rect.size.width += 12
        case .right:
            rect = rect.insetBy(dx: 0, dy: -12)
            rect.origin.x -= 12
            rect.size.width += 12
        }
        return growingOut(rect, by: 4)
    }

    /// Where the window takes clicks; everywhere else it is transparent to them.
    func interactiveRect(_ size: CGSize) -> CGRect {
        growingOut(bodyRect(size), by: 4)
    }

    /// The band along the docked edge where hover sampling runs at full rate.
    var warmZone: CGRect {
        let frame = screen.frame
        switch position {
        case .center: return CGRect(x: frame.minX, y: frame.maxY - 64, width: frame.width, height: 68)
        case .left: return CGRect(x: frame.minX - 4, y: frame.minY, width: 68, height: frame.height)
        case .right: return CGRect(x: frame.maxX - 64, y: frame.minY, width: 68, height: frame.height)
        }
    }
}

extension CGRect {
    func growingUp(_ amount: CGFloat) -> CGRect {
        CGRect(x: minX, y: minY, width: width, height: height + amount)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
