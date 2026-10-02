import CoreGraphics
import Observation

/// A brief message on the closed notch — a build or CI run that finished, a
/// focus round that ended, a screenshot that was stashed.
struct NotchFlash: Equatable, Sendable {
    let success: Bool?
    let title: String
    let detail: String
    /// Shown when `success` is nil; a hammer if not given.
    var symbol: String?
}

/// One display's share of the island: open or not, a drop hovering or not,
/// holding the keyboard or not. The pointer is on one display at a time, so
/// these belong to a screen; the section and the data belong to `HubModel`.
@MainActor
@Observable
final class ScreenSession {
    enum Change { case open, dropTarget, keyboard }

    var isOpen = false {
        didSet { if isOpen != oldValue { onChange?(.open) } }
    }
    var isDropTarget = false {
        didSet { if isDropTarget != oldValue { onChange?(.dropTarget) } }
    }
    /// Deliberately requested (landing on a typing section, clicking a field).
    var wantsKeyboard = false {
        didSet { if wantsKeyboard != oldValue { onChange?(.keyboard) } }
    }

    /// Shown on the closed notch for a few seconds; never interactive.
    var flash: NotchFlash?

    let metrics: ScreenMetrics
    @ObservationIgnored private let model: HubModel
    @ObservationIgnored var onChange: ((Change) -> Void)?

    init(metrics: ScreenMetrics, model: HubModel) {
        self.metrics = metrics
        self.model = model
    }

    var isActive: Bool { isOpen || isDropTarget }

    var openBodySize: CGSize { metrics.bodySize }

    #if DEBUG
    /// Snapshots only: freeze the body at an in-between size to inspect a
    /// frame of the open animation.
    var debugBodySize: CGSize?
    #endif

    var bodySize: CGSize {
        #if DEBUG
        if let debugBodySize { return debugBodySize }
        #endif
        if isActive { return openBodySize }
        if flash != nil {
            // At the top it widens the notch; on a side edge it slides out as a pill.
            return metrics.position.isSide
                ? CGSize(width: 260, height: 34)
                : CGSize(width: metrics.notch.width + 220, height: max(metrics.notch.height, 30))
        }
        if showsFocus {
            return metrics.position.isSide
                ? CGSize(width: 120, height: 34)
                : CGSize(width: metrics.notch.width + 130, height: max(metrics.notch.height, 30))
        }
        if showsAgents {
            return metrics.position.isSide
                ? CGSize(width: 14, height: ScreenMetrics.sideStripLength)
                : CGSize(width: metrics.notch.width + 300, height: max(metrics.notch.height, 30))
        }
        if showsBadge {
            return metrics.position.isSide
                ? CGSize(width: 14, height: ScreenMetrics.sideStripLength)
                : CGSize(width: metrics.collapsedSize.width + 56, height: max(metrics.collapsedSize.height, 20))
        }
        return metrics.collapsedSize
    }

    /// Agents at work (or waiting for the user), and no focus round showing.
    var showsAgents: Bool { model.agents.showsInNotch && !showsFocus }

    /// Unread inbox items and nothing louder on the closed notch.
    var showsBadge: Bool { model.inbox.badgeCount > 0 && !showsFocus && !showsAgents }

    /// A focus round is running and the closed notch shows its countdown.
    var showsFocus: Bool { model.focus.showsInNotch }

    /// Chosen on this screen, shown on all of them; only this one takes keys.
    func select(_ section: Section) {
        model.section = section
        if section.needsKeyboard { wantsKeyboard = true }
    }
}
