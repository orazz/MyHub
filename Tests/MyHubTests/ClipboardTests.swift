import AppKit
import CryptoKit
import Foundation
import Testing
@testable import MyHub

@Suite struct ClipHistoryTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func newestFirstAndCopyingAgainMovesToTop() {
        var history = ClipHistory(limit: 10)
        history.record(.text("a"), at: now, source: nil)
        history.record(.text("b"), at: now, source: nil)
        history.record(.text("a"), at: now, source: nil)
        #expect(history.entries.map(\.preview) == ["a", "b"])
    }

    @Test func limitDropsOldestButNeverPinned() {
        var history = ClipHistory(limit: 2)
        history.record(.text("keep"), at: now, source: nil)
        history.togglePin(history.entries[0].id)
        for text in ["1", "2", "3"] { history.record(.text(text), at: now, source: nil) }
        #expect(history.recent.map(\.preview) == ["3", "2"])
        #expect(history.pinned.map(\.preview) == ["keep"])
    }

    @Test func clearKeepsPinned() {
        var history = ClipHistory(limit: 10)
        history.record(.text("pinned"), at: now, source: nil)
        history.togglePin(history.entries[0].id)
        history.record(.text("loose"), at: now, source: nil)
        history.clearUnpinned()
        #expect(history.entries.map(\.preview) == ["pinned"])
    }

    @Test func duplicatesKeepTheirIdAndPin() {
        var history = ClipHistory(limit: 10)
        history.record(.text("x"), at: now, source: nil)
        let id = history.entries[0].id
        history.togglePin(id)
        history.record(.text("x"), at: now.addingTimeInterval(5), source: "Safari")
        #expect(history.entries.count == 1)
        #expect(history.entries[0].id == id)
        #expect(history.entries[0].pinned)
        #expect(history.entries[0].source == "Safari")
    }

    @Test func linksGetTheLinkSymbol() {
        var history = ClipHistory(limit: 10)
        history.record(.text("https://example.com/x"), at: now, source: nil)
        #expect(history.entries[0].symbol == "link")
    }
}

@Suite struct HistoryVaultTests {
    @Test func sealedHistoryRoundTripsAndIsNotPlaintext() throws {
        var history = ClipHistory(limit: 10)
        history.record(.text("hunter2-secret"), at: Date(), source: nil)
        let key = SymmetricKey(size: .bits256)
        let sealed = try HistoryVault.seal(history, with: key)
        #expect(sealed.range(of: Data("hunter2".utf8)) == nil)
        #expect(try HistoryVault.open(sealed, with: key) == history)
    }

    @Test func aDifferentKeyCannotOpenIt() throws {
        let sealed = try HistoryVault.seal(ClipHistory(limit: 5), with: SymmetricKey(size: .bits256))
        #expect(throws: (any Error).self) {
            try HistoryVault.open(sealed, with: SymmetricKey(size: .bits256))
        }
    }
}

@MainActor
@Suite struct PasteboardMonitorTests {
    let pasteboard = NSPasteboard(name: .init("com.orazz.myhub.tests.\(UUID().uuidString)"))
    let prefs: Preferences

    init() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubClip-\(UUID().uuidString).json")
        prefs = Preferences(file: file)
    }

    func monitor() -> PasteboardMonitor {
        PasteboardMonitor(preferences: prefs, pasteboard: pasteboard)
    }

    func put(_ text: String, extra: NSPasteboard.PasteboardType? = nil) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let extra { pasteboard.setData(Data(), forType: extra) }
    }

    @Test func recordsPlainText() {
        let monitor = monitor()
        put("hello")
        monitor.poll()
        #expect(monitor.history.entries.map(\.preview) == ["hello"])
    }

    @Test func skipsConcealedCopiesFromPasswordManagers() {
        let monitor = monitor()
        put("p@ssw0rd", extra: .init("org.nspasteboard.ConcealedType"))
        monitor.poll()
        #expect(monitor.history.entries.isEmpty)
    }

    @Test func skipsOurOwnWrites() {
        let monitor = monitor()
        put("from the stash", extra: .myHubOwnWrite)
        monitor.poll()
        #expect(monitor.history.entries.isEmpty)
    }

    @Test func skipsCopiesDeclaredFromAnExcludedApp() {
        let monitor = monitor()
        pasteboard.clearContents()
        pasteboard.setString("secret", forType: .string)
        pasteboard.setString("com.bitwarden.desktop", forType: .init("org.nspasteboard.source"))
        monitor.poll()
        #expect(monitor.history.entries.isEmpty)
    }

    @Test func ignoresAnUnchangedPasteboard() {
        let monitor = monitor()
        put("once")
        monitor.poll()
        monitor.clear()
        monitor.poll()
        #expect(monitor.history.entries.isEmpty)
    }

    @Test func copyingBackIsNotRecordedTwice() throws {
        let monitor = monitor()
        put("a"); monitor.poll()
        put("b"); monitor.poll()
        let a = try #require(monitor.history.entries.last)
        monitor.copy(a.id)
        monitor.poll()
        #expect(pasteboard.string(forType: .string) == "a")
        #expect(monitor.history.entries.map(\.preview) == ["a", "b"])
    }
}

@MainActor
@Suite struct ContentShieldTests {
    let prefs = Preferences(file: FileManager.default.temporaryDirectory.appendingPathComponent("MyHubShield-\(UUID().uuidString).json"))

    @Test func coversAndRevealsPerRowUntilFolded() {
        let shield = ContentShield(preferences: prefs)
        shield.setShielded(true, for: .clipboard)
        #expect(shield.masks("row", in: .clipboard))
        #expect(!shield.masks("row", in: .notes))
        shield.togglePeek("row")
        #expect(!shield.masks("row", in: .clipboard))
        shield.endPeeks()
        #expect(shield.masks("row", in: .clipboard))
    }

    @Test func choicePersistsButRevealsDoNot() {
        let shield = ContentShield(preferences: prefs)
        shield.setShieldedEverywhere(true)
        shield.togglePeek("row")
        let again = ContentShield(preferences: prefs)
        #expect(again.coverage == .all)
        #expect(again.masks("row", in: .calendar))
    }

    @Test func settingsAndStashCannotBeCovered() {
        let shield = ContentShield(preferences: prefs)
        shield.setShielded(true, for: .settings)
        shield.setShielded(true, for: .stash)
        #expect(shield.coverage == .none)
    }
}
