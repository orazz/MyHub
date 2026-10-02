import Carbon.HIToolbox

/// One tool in the dock and the pane it opens. Everything the dock and the
/// window layer need to know about a section is described here, so adding one
/// is a new case plus a view — not a hunt through switch statements.
enum Section: String, CaseIterable, Identifiable, Sendable {
    case stash, inbox, agents, clipboard, calendar, notes, focus, usage, jira, builds, dev, settings

    var id: String { rawValue }

    /// SF Symbols per the handoff's icon mapping.
    var symbol: String {
        switch self {
        case .stash: "tray"
        case .inbox: "bell"
        case .agents: "cpu"
        case .clipboard: "doc.on.clipboard"
        case .calendar: "calendar"
        case .notes: "square.and.pencil"
        case .focus: "timer"
        case .usage: "sparkles"
        case .jira: "rectangle.split.3x1"
        case .builds: "hammer"
        case .dev: "chevron.left.forwardslash.chevron.right"
        case .settings: "slider.horizontal.3"
        }
    }

    var title: String {
        switch self {
        case .stash: L10n.string("Stash")
        case .inbox: L10n.string("Inbox")
        case .agents: L10n.string("Agents")
        case .clipboard: L10n.string("Clipboard")
        case .calendar: L10n.string("Calendar")
        case .notes: L10n.string("Notes")
        case .focus: L10n.string("Focus")
        case .usage: L10n.string("AI usage")
        case .jira: "Jira"
        case .builds: L10n.string("Builds")
        case .dev: L10n.string("Dev")
        case .settings: L10n.string("Settings")
        }
    }

    /// Landing here hands the panel the keyboard, so arriving and typing is
    /// one move: the clipboard's search and keyboard navigation, the notes.
    var needsKeyboard: Bool { self == .notes || self == .clipboard }

    /// ⌥ plus this key switches to the section while the panel is open. Mostly
    /// the first letter; the next free one where that is taken; "," for
    /// Settings, as in every Mac app.
    var switchKey: (label: String, keyCode: Int) {
        switch self {
        case .stash: ("S", kVK_ANSI_S)
        case .inbox: ("I", kVK_ANSI_I)
        case .agents: ("G", kVK_ANSI_G)
        case .clipboard: ("C", kVK_ANSI_C)
        case .calendar: ("A", kVK_ANSI_A)
        case .notes: ("N", kVK_ANSI_N)
        case .focus: ("F", kVK_ANSI_F)
        case .usage: ("U", kVK_ANSI_U)
        case .jira: ("J", kVK_ANSI_J)
        case .builds: ("B", kVK_ANSI_B)
        case .dev: ("D", kVK_ANSI_D)
        case .settings: (",", kVK_ANSI_Comma)
        }
    }

    /// Settings can never be hidden — it is the way back.
    var canHide: Bool { self != .settings }

    /// The tools on the left of the dock; Settings sits alone on the right.
    static let tools: [Section] = [.stash, .inbox, .agents, .clipboard, .calendar, .notes, .focus, .usage, .jira, .builds, .dev]
}
