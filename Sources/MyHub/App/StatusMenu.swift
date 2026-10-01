import AppKit

/// The menu bar item: toggle the island, privacy shield, quit. It can be
/// ⌘-dragged off the bar; launching MyHub again while it runs brings it back.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let coordinator: IslandCoordinator
    /// Refilled every time the menu opens, so it always shows the current
    /// state without anything having to keep it in sync.
    private let shieldMenu = NSMenu()

    private var shield: ContentShield { coordinator.model.shield }

    init(coordinator: IslandCoordinator) {
        self.coordinator = coordinator
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configure()
        coordinator.model.onUsageMeterChange = { [weak self] in self?.updateMeter() }
        updateMeter()
    }

    /// The figures the user pinned next to the icon: the fullest AI limit and
    /// today's build time, as "27% · 12m". Plain text — the status bar picks
    /// the colour for light, dark and tinted menu bars.
    func updateMeter() {
        let model = coordinator.model
        guard let button = item.button else { return }
        var parts: [String] = []
        var tips: [String] = []
        if model.preferences.values.usage.menuBarMeter, let top = model.usage.headline {
            let percent = Int((top.used * 100).rounded())
            parts.append("\(percent)%" + (top.used >= 0.9 ? "!" : ""))
            tips.append("\(top.label): \(percent)%")
        }
        if model.preferences.values.builds.menuBarTime {
            let today = model.builds.todayTotal
            parts.append(BuildStats.duration(today))
            tips.append(L10n.format("Building today: %@", BuildStats.duration(today)))
        }
        guard !parts.isEmpty else {
            button.title = ""
            button.imagePosition = .imageOnly
            item.length = NSStatusItem.squareLength
            return
        }
        button.attributedTitle = NSAttributedString(
            string: " " + parts.joined(separator: " · "),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]
        )
        button.imagePosition = .imageLeading
        button.toolTip = tips.joined(separator: "\n")
        item.length = NSStatusItem.variableLength
    }

    func reveal() {
        item.isVisible = true
    }

    private func configure() {
        let image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "MyHub")
        image?.isTemplate = true
        item.button?.image = image
        item.behavior = .removalAllowed
        item.autosaveName = "MyHubStatusItem"

        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "MyHub \(Bundle.main.appVersion)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(entry(L10n.string("Toggle Panel"), #selector(togglePanel)))
        menu.addItem(entry(L10n.string("Measure Screen"), #selector(measureScreen)))
        menu.addItem(shieldEntry())
        menu.addItem(.separator())
        menu.addItem(entry(L10n.string("Quit MyHub"), #selector(quit), key: "q"))
        item.menu = menu
    }

    private func entry(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    // MARK: Privacy shield

    /// Beside the panel toggle rather than buried in Settings: it gets used in
    /// a hurry, often with a call already being shared.
    private func shieldEntry() -> NSMenuItem {
        let parent = NSMenuItem(title: L10n.string("Privacy Shield"), action: nil, keyEquivalent: "")
        shieldMenu.delegate = self
        shieldMenu.autoenablesItems = false
        parent.submenu = shieldMenu
        return parent
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === shieldMenu else { return }
        let shield = self.shield
        menu.removeAllItems()
        // "Everything" is ticked only when it is literally everything; from a
        // partial state, choosing it fills in the rest.
        let everything = ActionItem(L10n.string("Everything")) { shield.setShieldedEverywhere(shield.coverage != .all) }
        everything.state = shield.coverage == .all ? .on : .off
        menu.addItem(everything)
        menu.addItem(.separator())
        for section in ContentShield.eligible {
            let row = ActionItem(section.title) { shield.setShielded(!shield.isShielded(section), for: section) }
            row.state = shield.isShielded(section) ? .on : .off
            menu.addItem(row)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === item.menu, let parent = menu.items.first(where: { $0.submenu === shieldMenu }) else { return }
        parent.state = switch shield.coverage {
        case .all: .on
        case .some: .mixed
        case .none: .off
        }
    }

    @objc private func togglePanel() {
        coordinator.togglePanel()
    }

    @objc private func measureScreen() {
        coordinator.model.ruler.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// A menu item that runs a closure, for menus rebuilt on every opening.
@MainActor
private final class ActionItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(_ title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not used from a nib") }

    @objc private func fire() { run() }
}
