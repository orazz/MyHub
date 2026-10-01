import AppKit

/// Ties the single `HubModel` to an `IslandScreen` on each display.
///
/// Plugging in a monitor, closing the lid or changing a resolution all
/// reshuffle the displays while MyHub keeps running. The model is untouched
/// by that; per display, an island is rebuilt only if its geometry differs.
@MainActor
final class IslandCoordinator {
    let model: HubModel
    private var screens: [CGDirectDisplayID: IslandScreen] = [:]
    private var watchers: [Task<Void, Never>] = []

    init(model: HubModel) {
        self.model = model
    }

    func install() {
        model.onSectionChange = { [weak self] section in
            self?.screens.values.forEach { $0.sectionDidChange(section) }
        }
        model.onDisplayLayoutChange = { [weak self] in self?.rebuild() }
        model.onCollapseRequest = { [weak self] in self?.screens.values.forEach { $0.collapse() } }
        model.onBuildFinished = { [weak self] record in
            let flash = NotchFlash(
                success: record.map { $0.status == .unknown ? nil : $0.status == .success } ?? nil,
                title: record?.name ?? L10n.string("Build finished"),
                detail: record.map { BuildFormat.clock($0.duration) } ?? ""
            )
            self?.screens.values.forEach { $0.showFlash(flash) }
        }
        model.onFlash = { [weak self] flash in
            self?.screens.values.forEach { $0.showFlash(flash) }
        }
        model.start()
        rebuild()

        let workspace = NSWorkspace.shared.notificationCenter
        on(NSApplication.didChangeScreenParametersNotification) { $0.rebuild() }
        on(NSWorkspace.activeSpaceDidChangeNotification, in: workspace) { $0.screens.values.forEach { $0.collapse() } }
        on(NSWorkspace.screensDidSleepNotification, in: workspace) { $0.screens.values.forEach { $0.screensSlept() } }
        on(NSWorkspace.screensDidWakeNotification, in: workspace) { $0.screens.values.forEach { $0.screensWoke() } }
    }

    func teardown() {
        watchers.forEach { $0.cancel() }
        watchers = []
        model.stop()
        screens.values.forEach { $0.teardown() }
        screens.removeAll()
    }

    /// From the menu bar or the shortcut: the display the pointer is on,
    /// else the main one.
    func togglePanel() {
        targetScreen()?.toggle()
    }

    /// ⌘⇧V: straight to the clipboard, keyboard ready.
    func openPanel(on section: Section) {
        guard model.isVisible(section) else { return }
        targetScreen()?.open(on: section)
    }

    private func targetScreen() -> IslandScreen? {
        let point = NSEvent.mouseLocation
        return screens.values.first { $0.metrics.screen.frame.contains(point) }
            ?? NSScreen.main?.displayID.flatMap { screens[$0] }
            ?? screens.values.first
    }

    /// Runs `act` for every `name` posted on `center` until `teardown`.
    private func on(_ name: Notification.Name, in center: NotificationCenter = .default, _ act: @escaping @MainActor (IslandCoordinator) -> Void) {
        watchers.append(Task { [weak self] in
            for await _ in center.notifications(named: name).map({ _ in () }) {
                guard let self else { return }
                act(self)
            }
        })
    }

    // MARK: - Displays

    /// Matched up by `CGDirectDisplayID`. `NSScreen` objects are recreated on
    /// each change and their array order is not stable, so neither identity
    /// nor index says which island belongs to which display.
    private func rebuild() {
        var next: [CGDirectDisplayID: IslandScreen] = [:]
        for metrics in ScreenMetrics.current(model.preferences.values) {
            let existing = screens.removeValue(forKey: metrics.displayID)
            if let existing, existing.metrics.matches(metrics) {
                existing.setFrame(metrics.windowFrame)
                next[metrics.displayID] = existing
            } else {
                // A rebuild while the panel is open (a new panel size picked in
                // Settings) reopens it on the same screen rather than folding
                // it out from under the pointer.
                let wasOpen = existing?.session.isOpen ?? false
                existing?.teardown()
                let screen = IslandScreen(metrics: metrics, model: model)
                screen.onStateChange = { [weak self] in self?.refreshShared() }
                next[metrics.displayID] = screen
                if wasOpen { screen.open(on: nil) }
            }
        }
        screens.values.forEach { $0.teardown() }
        screens = next
        refreshShared()
        Log.island.debug("islands on \(next.count, privacy: .public) display(s)")
    }

    /// ⌥-letter tab shortcuts are wanted: a panel is open and nobody is
    /// typing (⌥ letters type accents in a field).
    var onTabKeysWanted: ((Bool) -> Void)?
    private var tabKeysWanted = false

    /// From ⌥← / ⌥→: the previous or next tab in the dock, wrapping around.
    func stepTab(by offset: Int) {
        let tabs = model.railSections
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex(of: model.section) ?? 0
        model.section = tabs[(current + offset + tabs.count) % tabs.count]
    }

    /// From an ⌥-letter shortcut: switch the open panel's tab.
    func switchTab(to section: Section) {
        guard model.isVisible(section) else { return }
        model.section = section
    }

    private func refreshShared() {
        model.isTyping = screens.values.contains { $0.session.wantsKeyboard }
        let open = screens.values.contains { $0.session.isOpen }
        let wanted = open && !model.isTyping
        if wanted != tabKeysWanted {
            tabKeysWanted = wanted
            onTabKeysWanted?(wanted)
        }
        if !wanted { model.showsTabKeys = false }
        let active = screens.values.contains { $0.session.isActive }
        model.setPanelActive(active)
        // All islands folded: peeks at shielded rows end here.
        if !active { model.shield.endPeeks() }
    }
}
