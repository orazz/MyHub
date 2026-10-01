import Foundation
import Testing
@testable import MyHub

@MainActor
@Suite struct PreferencesTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func missingFileIsCreatedWithDefaultsAndPrivatePermissions() throws {
        let file = folder.appendingPathComponent("prefs.json")
        let prefs = Preferences(file: file)
        #expect(prefs.values == Preferences.Values())
        #expect(FileManager.default.fileExists(atPath: file.path))
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func missingKeysTakeDefaultsIncludingNestedOnes() throws {
        let file = folder.appendingPathComponent("prefs.json")
        try Data(#"{"showOnAllDisplays": false, "clipboard": {"historyLimit": 10}}"#.utf8).write(to: file)
        let prefs = Preferences(file: file)
        #expect(prefs.values.showOnAllDisplays == false)
        #expect(prefs.values.clipboard.historyLimit == 10)
        #expect(prefs.values.clipboard.excludedBundleIDs == Preferences.Clipboard().excludedBundleIDs)
        #expect(!prefs.isFileBroken)
    }

    @Test func aBrokenFileIsNeverOverwritten() throws {
        let file = folder.appendingPathComponent("prefs.json")
        let original = Data("{ not json".utf8)
        try original.write(to: file)
        let prefs = Preferences(file: file)
        #expect(prefs.isFileBroken)
        prefs.update { $0.showOnAllDisplays = false }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func updatesRoundTrip() {
        let file = folder.appendingPathComponent("prefs.json")
        Preferences(file: file).update { $0.hiddenSections = ["notes"] }
        #expect(Preferences(file: file).values.hiddenSections == ["notes"])
    }

    @Test func settingsSavedBeforeTheStashRenameCarryOver() throws {
        let file = folder.appendingPathComponent("prefs.json")
        try Data(#"{"general": {"lastSection": "shelf"}, "hiddenSections": ["shelf", "notes"], "shieldedSections": ["shelf"], "clipboard": {"saveImagesToShelf": true}}"#.utf8).write(to: file)
        let values = Preferences(file: file).values
        #expect(values.general.lastSection == "stash")
        #expect(values.hiddenSections == ["stash", "notes"])
        #expect(values.shieldedSections == ["stash"])
        #expect(values.clipboard.saveImagesToStash)
    }
}
