import AppKit

/// Process entry point. MyHub is an accessory app: no Dock icon, no main
/// menu, just the menu-bar item and the islands.
@main
enum MyHubApp {
    @MainActor
    static func main() {
        let delegate = HubAppDelegate()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.delegate = delegate
        // The application only holds its delegate weakly.
        withExtendedLifetime(delegate) { NSApplication.shared.run() }
    }
}
