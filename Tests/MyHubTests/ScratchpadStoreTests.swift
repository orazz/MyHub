import Foundation
import Testing
@testable import MyHub

@MainActor
@Suite struct ScratchpadStoreTests {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubNotes-\(UUID().uuidString).json")

    func store() -> ScratchpadStore { ScratchpadStore(file: file, saveDelay: .seconds(60)) }

    @Test func arrivingOnAnEmptyPadCreatesANoteReadyToType() {
        let pad = store()
        pad.arrive()
        #expect(pad.notes.count == 1)
        #expect(pad.selected?.isBlank == true)
        pad.arrive()
        #expect(pad.notes.count == 1)
    }

    @Test func leavingSweepsBlankNotesAndSaves() throws {
        let pad = store()
        pad.add()
        pad.update(try #require(pad.selectedID), text: "keep me")
        pad.add()
        pad.leave()
        #expect(pad.notes.map(\.text) == ["keep me"])
        #expect(pad.selected?.text == "keep me")
        #expect(store().notes.map(\.text) == ["keep me"])
    }

    @Test func titleIsTheFirstNonEmptyLine() {
        let note = Note(id: UUID(), text: "\n  \n  Call Anna  \nabout the lease", created: .now, edited: .now, pinned: false)
        #expect(note.title == "Call Anna")
    }

    @Test func orderIsPinnedThenNewestAndStableOnEdit() throws {
        let pad = store()
        for text in ["one", "two", "three"] {
            pad.add()
            pad.update(try #require(pad.selectedID), text: text)
        }
        #expect(pad.ordered.map(\.text) == ["three", "two", "one"])
        let one = try #require(pad.notes.first { $0.text == "one" })
        pad.update(one.id, text: "one, edited")
        #expect(pad.ordered.map(\.text) == ["three", "two", "one, edited"])
        pad.togglePin(one.id)
        #expect(pad.ordered.map(\.text) == ["one, edited", "three", "two"])
    }

    @Test func filterIsCaseInsensitive() throws {
        let pad = store()
        for text in ["Wi-Fi password is on the fridge", "Buy milk"] {
            pad.add()
            pad.update(try #require(pad.selectedID), text: text)
        }
        pad.filter = "wi-fi"
        #expect(pad.visible.map(\.title) == ["Wi-Fi password is on the fridge"])
    }

    @Test func deletingSelectsTheNeighbourBelow() throws {
        let pad = store()
        for text in ["c", "b", "a"] {
            pad.add()
            pad.update(try #require(pad.selectedID), text: text)
        }
        let b = try #require(pad.notes.first { $0.text == "b" })
        pad.selectedID = b.id
        pad.remove(b.id)
        #expect(pad.selected?.text == "c")
    }

    @Test func aBrokenFileIsNeverOverwritten() throws {
        let original = Data("[{ half a note".utf8)
        try original.write(to: file)
        let pad = store()
        #expect(pad.isFileBroken)
        pad.add()
        pad.flush()
        #expect(try Data(contentsOf: file) == original)
    }
}
