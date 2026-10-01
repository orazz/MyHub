import AppKit
import Carbon.HIToolbox

@MainActor
final class HubAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: IslandCoordinator?
    private var statusMenu: StatusMenu?
    private var hotKeys: HotKeys?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = IslandCoordinator(model: HubModel(preferences: .shared, stash: StashStore()))
        coordinator.install()
        self.coordinator = coordinator
        statusMenu = StatusMenu(coordinator: coordinator)
        let hotKeys = HotKeys()
        self.hotKeys = hotKeys
        registerShortcuts()
        coordinator.model.onShortcutChange = { [weak self] in self?.registerShortcuts() }
        coordinator.onTabKeysWanted = { [weak self] wanted in self?.setTabKeys(wanted) }
        coordinator.model.onShortcutRecording = { [weak self] recording in
            if recording {
                self?.hotKeys?.unregister(1)
                self?.hotKeys?.unregister(3)
            } else {
                self?.registerShortcuts()
            }
        }
        Log.app.info("MyHub \(Bundle.main.appVersion, privacy: .public) started")
    }

    /// ⌥Space (configurable) toggles the island; ⌘⇧V opens the clipboard;
    /// ⌃⌥M (configurable) measures the screen; ⌃⌥S opens the snippets.
    private func registerShortcuts() {
        guard let coordinator, let hotKeys else { return }
        hotKeys.register(1, coordinator.model.preferences.values.general.toggleShortcut) { [weak coordinator] in
            coordinator?.togglePanel()
        }
        hotKeys.register(2, .clipboard) { [weak coordinator] in
            coordinator?.openPanel(on: .clipboard)
        }
        hotKeys.register(3, coordinator.model.preferences.values.design.rulerShortcut) { [weak coordinator] in
            coordinator?.model.ruler.toggle()
        }
        hotKeys.register(4, .snippets) { [weak coordinator] in
            coordinator?.model.notesMode = .snippets
            coordinator?.openPanel(on: .notes)
        }
    }

    /// ⌥S, ⌥I, ⌥C … and ⌥← / ⌥→ switch tabs, but only while a panel is open
    /// and nobody is typing — the rest of the time those keys belong to
    /// whatever app is in front (⌥← / ⌥→ move by word in text).
    private func setTabKeys(_ on: Bool) {
        guard let coordinator, let hotKeys else { return }
        for (index, section) in Section.allCases.enumerated() {
            let number = UInt32(100 + index)
            if on, coordinator.model.isVisible(section) {
                let shortcut = Shortcut(keyCode: UInt32(section.switchKey.keyCode), modifiers: UInt32(optionKey))
                hotKeys.register(number, shortcut) { [weak coordinator] in coordinator?.switchTab(to: section) }
            } else {
                hotKeys.unregister(number)
            }
        }
        // ⌥← / ⌥→ step through the dock.
        for (number, keyCode, offset) in [(UInt32(200), kVK_LeftArrow, -1), (UInt32(201), kVK_RightArrow, 1)] {
            if on {
                hotKeys.register(number, Shortcut(keyCode: UInt32(keyCode), modifiers: UInt32(optionKey))) { [weak coordinator] in
                    coordinator?.stepTab(by: offset)
                }
            } else {
                hotKeys.unregister(number)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.teardown()
    }

    /// With no Dock icon and no window, relaunching the app is the gesture
    /// that brings a removed menu bar icon back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusMenu?.reveal()
        return true
    }
}
