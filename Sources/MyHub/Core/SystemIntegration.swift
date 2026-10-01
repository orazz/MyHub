import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

/// Pastes into the frontmost app by posting ⌘V. macOS allows synthetic key
/// events only for apps the user has granted Accessibility; without it this
/// does nothing and the entry simply waits on the clipboard.
enum Paster {
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security → Accessibility.
    static func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func pasteIntoFrontApp(after delay: Duration) {
        guard isAllowed else { return }
        Task {
            try? await Task.sleep(for: delay)
            let source = CGEventSource(stateID: .combinedSessionState)
            let v = CGKeyCode(kVK_ANSI_V)
            let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

/// Launch at login through `SMAppService` — the system's own login-items
/// list, which the user can also see and change in System Settings.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns the resulting state; registration can fail for an app run
    /// from a build folder or a disk image.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("login item: \(error.localizedDescription, privacy: .public)")
        }
        return isEnabled
    }
}

/// A light tick on the trackpad (only Force Touch trackpads have one).
enum Haptics {
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// System-wide shortcuts through Carbon's `RegisterEventHotKey` — the one
/// hotkey API that needs no Accessibility permission. Handlers run on the
/// main thread.
@MainActor
final class HotKeys {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4D59_4842 // "MYHB"

    /// The one instance the C callback can reach.
    private static weak var current: HotKeys?

    init() {
        HotKeys.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = id.id
            MainActor.assumeIsolated { HotKeys.current?.actions[number]?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    func register(_ number: UInt32, _ shortcut: Shortcut, action: @escaping () -> Void) {
        unregister(number)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: number)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.app.error("hotkey \(shortcut.display, privacy: .public) is taken (\(status, privacy: .public))")
            return
        }
        refs[number] = ref
        actions[number] = action
    }

    func unregister(_ number: UInt32) {
        if let ref = refs.removeValue(forKey: number) { UnregisterEventHotKey(ref) }
        actions[number] = nil
    }
}
