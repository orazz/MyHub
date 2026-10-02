import AppKit
import Foundation
import Testing
@testable import MyHub

@MainActor
@Suite struct StashStoreTests {
    let folder: URL
    let store: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubStash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = folder.appendingPathComponent("stash.json")
    }

    func makeFile(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    func library(limit: Int = 60) -> StashStore {
        StashStore(file: store, limit: limit, rendersPreviews: false)
    }

    @Test func onlyFilesCanBeEmailed() throws {
        let stash = library()
        let file = try makeFile("Invoice.pdf")
        let subfolder = folder.appendingPathComponent("Designs", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        stash.add([file, subfolder])
        let ids = Set(stash.items.map(\.id))
        #expect(stash.emailable(ids).map(\.lastPathComponent) == ["Invoice.pdf"])
        #expect(stash.emailable([]).isEmpty)
    }

    @Test func theQuestionBarFollowsTheStash() throws {
        let stash = library()
        let a = try makeFile("brief.md"), b = try makeFile("mock.png")
        stash.add([a, b])
        let ids = stash.items.map(\.id)
        stash.beginAsking(Set(ids))
        #expect(stash.askableFiles.map(\.lastPathComponent) == ["brief.md", "mock.png"])
        stash.remove(ids[0])
        #expect(stash.askableFiles.map(\.lastPathComponent) == ["mock.png"])
        stash.cancelAsking()
        #expect(stash.askingAbout.isEmpty)
    }

    @Test func keepsDropOrderNewestFirstAndDedupes() throws {
        let a = try makeFile("a.txt"), b = try makeFile("b.txt"), c = try makeFile("c.txt")
        let stash = library()
        stash.add([a, b])
        stash.add([c])
        #expect(stash.items.map(\.name) == ["c.txt", "a.txt", "b.txt"])
        stash.add([b])
        #expect(stash.items.map(\.name) == ["b.txt", "c.txt", "a.txt"])
    }

    @Test func trimsTheOldestPastTheLimit() throws {
        let stash = library(limit: 2)
        for name in ["1", "2", "3"] { stash.add([try makeFile(name)]) }
        #expect(stash.items.map(\.name) == ["3", "2"])
    }

    @Test func survivesARelaunchWithoutTouchingFiles() throws {
        let a = try makeFile("a.txt")
        library().add([a])
        try FileManager.default.removeItem(at: a)
        // Loading must not check the disk: the card is still there until refresh.
        #expect(library().items.map(\.name) == ["a.txt"])
    }

    @Test func refreshDropsDeletedFilesAndKeepsTheRest() async throws {
        let a = try makeFile("a.txt"), b = try makeFile("b.txt")
        let stash = library()
        stash.add([a, b])
        try FileManager.default.removeItem(at: a)
        await stash.refresh()
        #expect(stash.items.map(\.name) == ["b.txt"])
    }

    @Test func refreshFollowsARenamedFile() async throws {
        let a = try makeFile("draft.txt")
        let stash = library()
        stash.add([a])
        try FileManager.default.moveItem(at: a, to: folder.appendingPathComponent("final.txt"))
        await stash.refresh()
        #expect(stash.items.map(\.name) == ["final.txt"])
        #expect(library().items.map(\.name) == ["final.txt"])
    }

    @Test func selectionFollowsFinderRules() throws {
        let stash = library()
        stash.add([try makeFile("a"), try makeFile("b"), try makeFile("c")])
        let ids = stash.items.map(\.id)

        stash.select(ids[0], extending: false)
        #expect(stash.selection == [ids[0]])
        stash.select(ids[1], extending: true)
        #expect(stash.selection == [ids[0], ids[1]])
        stash.select(ids[1], extending: true)
        #expect(stash.selection == [ids[0]])
        stash.select(ids[0], extending: false)
        #expect(stash.selection.isEmpty)
    }

    @Test func dragCarriesTheSelectionOnlyWhenStartedOnIt() throws {
        let stash = library()
        stash.add([try makeFile("a"), try makeFile("b"), try makeFile("c")])
        let ids = stash.items.map(\.id)
        stash.select(ids[0], extending: false)
        stash.select(ids[1], extending: true)
        #expect(stash.dragURLs(startingAt: ids[1]).count == 2)
        #expect(stash.dragURLs(startingAt: ids[2]).map(\.lastPathComponent) == ["c"])
    }

    @Test func removingForgetsSelection() throws {
        let stash = library()
        stash.add([try makeFile("a")])
        let id = try #require(stash.items.first?.id)
        stash.select(id, extending: false)
        stash.remove(id)
        #expect(stash.items.isEmpty)
        #expect(stash.selection.isEmpty)
    }
}
