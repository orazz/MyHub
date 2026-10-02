import AppKit
import SwiftUI
import Testing
@testable import MyHub

/// Opt-in: `MYHUB_PERF=1 swift test --filter PanelPerformance` draws each tab
/// of the open panel repeatedly, offscreen, and prints the time per frame —
/// to find the expensive tabs without touching the screen.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MYHUB_PERF"] == "1"))
struct PanelPerformance {
    @Test func drawCostPerTab() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubPerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let prefs = Preferences(file: temp.appendingPathComponent("prefs.json"))
        let model = HubModel(preferences: prefs, stash: StashStore(file: temp.appendingPathComponent("stash.json"), rendersPreviews: false),
                             notesFile: temp.appendingPathComponent("notes.json"), buildHistoryFile: temp.appendingPathComponent("b.json"))
        let now = Date()
        // A realistic history: a year of builds across five schemes.
        model.builds.injectHistoryForPreview((0..<3000).map { i in
            let end = now.addingTimeInterval(-Double(i) * 3600 * 2.9)
            return BuildRecord(id: "r\(i)", name: ["Orbit", "OrbitKit", "Widgets", "Watch", "Tests"][i % 5],
                               status: i % 17 == 0 ? .failure : .success, started: end.addingTimeInterval(-Double(40 + i % 200)), finished: end)
        })
        model.builds.mode = .stats
        var cycle = FocusCycle()
        cycle.start(at: now, lengths: model.focus.lengths)
        model.focus.injectForPreview(cycle)

        for (theme, size) in [(PanelTheme.classic, PanelSize.standard), (.aurora, .extraLarge)] {
            ThemeState.shared.theme = theme
            guard let screen = NSScreen.screens.first,
                  let metrics = ScreenMetrics(screen: screen, fullHeightDrawn: false, panelSize: size) else { return }
            let session = ScreenSession(metrics: metrics, model: model)
            session.isOpen = true
            let hosting = NSHostingView(rootView: IslandRootView(model: model, session: session)
                .frame(width: metrics.windowSize.width, height: metrics.windowSize.height))
            hosting.frame = CGRect(origin: .zero, size: metrics.windowSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            var lines: [String] = []
            for section in [Section.stash, .inbox, .clipboard, .calendar, .notes, .focus, .usage, .builds, .dev, .settings] {
                model.section = section
                hosting.layoutSubtreeIfNeeded()
                let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
                hosting.cacheDisplay(in: hosting.bounds, to: rep)       // warm up
                let clock = ContinuousClock()
                let frames = 30
                let elapsed = clock.measure {
                    for _ in 0..<frames {
                        hosting.needsDisplay = true
                        hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    }
                }
                let ms = Double(elapsed.components.attoseconds) / 1e15 / Double(frames) + Double(elapsed.components.seconds) * 1000 / Double(frames)
                lines.append(String(format: "%-10@ %6.2f ms", section.rawValue as NSString, ms))
            }
            print("PERF \(theme.rawValue)/\(size.rawValue):\n  " + lines.joined(separator: "\n  "))
        }
        ThemeState.shared.theme = .classic
    }
}
