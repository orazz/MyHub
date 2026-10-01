import Foundation
import Observation

struct Note: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var text: String
    let created: Date
    var edited: Date
    var pinned: Bool

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Notes have no title field; the opening line serves as one. Jotting
    /// should not start with a form.
    var title: String {
        text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// A scratchpad, not a notes app: jot, come back, delete, or carry it off
/// through the clipboard. No folders, no formatting.
///
/// - Arriving with nothing there creates an empty note, caret ready.
/// - Blank notes sweep themselves out when the section is left.
/// - Order is pinned first, then newest first — and never changes on edit: a
///   list that reshuffles while you type loses your place.
/// - Saved a moment after typing pauses; flushed on quit. A `notes.json` that
///   fails to parse is never overwritten (it is the one text here that cannot
///   be re-derived from anywhere).
@MainActor
@Observable
final class ScratchpadStore {
    private(set) var notes: [Note] = []
    var selectedID: Note.ID?
    var filter = ""
    private(set) var isFileBroken = false

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let saves: WriteCoalescer

    init(file: URL = AppPaths.file("notes.json"), saveDelay: Duration = .milliseconds(800)) {
        self.file = file
        self.saves = WriteCoalescer(delay: saveDelay)
        load()
    }

    // MARK: - Reading

    var ordered: [Note] {
        notes.filter(\.pinned) + notes.filter { !$0.pinned }
    }

    var visible: [Note] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var selected: Note? {
        selectedID.flatMap { id in notes.first { $0.id == id } }
    }

    // MARK: - Section lifecycle

    /// Landing on the section: there is always something to type into.
    func arrive() {
        if notes.isEmpty {
            add()
        } else if selected == nil {
            selectedID = ordered.first?.id
        }
    }

    /// Leaving the section: blank notes go, the rest reaches the disk.
    func leave() {
        let blank = Set(notes.filter(\.isBlank).map(\.id))
        if !blank.isEmpty {
            notes.removeAll { blank.contains($0.id) }
            if let selectedID, blank.contains(selectedID) { self.selectedID = ordered.first?.id }
            saveSoon()
        }
        filter = ""
        flush()
    }

    // MARK: - Editing

    func add() {
        let now = Date()
        let note = Note(id: UUID(), text: "", created: now, edited: now, pinned: false)
        notes.insert(note, at: 0)
        selectedID = note.id
        filter = ""
        saveSoon()
    }

    func update(_ id: Note.ID, text: String) {
        modify(id) { note in
            guard note.text != text else { return false }
            note.text = text
            note.edited = Date()
            return true
        }
    }

    func togglePin(_ id: Note.ID) {
        modify(id) { note in
            note.pinned.toggle()
            return true
        }
    }

    /// Applies `change` to one note in place; a save follows only when the
    /// change reports that it did something.
    private func modify(_ id: Note.ID, _ change: (inout Note) -> Bool) {
        for index in notes.indices where notes[index].id == id {
            if change(&notes[index]) { saves.schedule { [weak self] in self?.persist() } }
            return
        }
    }

    /// The neighbour below takes the selection, so deleting several in a row
    /// needs no aiming.
    func remove(_ id: Note.ID) {
        let list = ordered
        guard let position = list.firstIndex(where: { $0.id == id }) else { return }
        notes.removeAll { $0.id == id }
        if selectedID == id {
            let rest = list.filter { $0.id != id }
            selectedID = rest.isEmpty ? nil : rest[min(position, rest.count - 1)].id
        }
        saveSoon()
    }

    // MARK: - Persistence

    func flush() { saves.flush() }

    private func saveSoon() {
        saves.schedule { [weak self] in self?.persist() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            notes = try JSONDecoder.iso.decode([Note].self, from: data)
            selectedID = ordered.first?.id
        } catch {
            isFileBroken = true
            Log.storage.error("notes.json is unreadable; it will not be overwritten: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        guard !isFileBroken else { return }
        do {
            try AppPaths.writePrivate(try JSONEncoder.iso.encode(notes), to: file)
        } catch {
            Log.storage.error("cannot write notes.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension JSONEncoder {
    /// Readable dates for files a person might open.
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
