import AppKit
import Testing
@testable import MyHub

@MainActor
@Suite struct IslandWindowTests {
    /// Regression: `isFloatingPanel` reset the level to `.floating`, AppKit
    /// pushed the window below the menu bar, and the bottom of the panel
    /// stopped taking clicks.
    @Test func sitsAboveTheMenuBarAtItsExactFrame() {
        let frame = CGRect(x: 100, y: 500, width: 700, height: 252)
        let window = IslandWindow(frame: frame)
        #expect(window.level == IslandWindow.islandLevel)
        #expect(window.level.rawValue > NSWindow.Level.statusBar.rawValue)
        #expect(window.constrainFrameRect(frame, to: NSScreen.main) == frame)
    }
}
