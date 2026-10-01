import Foundation
import Observation

/// Reusable text — an email reply, a code block, a hex value — pasted with a
/// click, with a few placeholders filled in at paste time.
struct Snippet: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var body: String
    var edited: Date

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return body.split(whereSeparator: \.isNewline).first.map { String($0.prefix(40)) } ?? ""
    }
}

/// `{{date}}`, `{{time}}`, `{{datetime}}`, `{{iso}}`, `{{clipboard}}`,
/// `{{uuid}}`. Double braces, so code with single braces is left alone;
/// unknown names are kept as typed.
enum SnippetExpander {
    static let placeholders = ["date", "time", "datetime", "iso", "clipboard", "uuid"]

    static func expand(_ text: String, now: Date = Date(), clipboard: String? = nil,
                       uuid: () -> UUID = UUID.init, locale: Locale = .current) -> String {
        guard text.contains("{{") else { return text }
        var result = ""
        var rest = text[...]
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let name = after[..<close.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
            switch name {
            case "date": result += now.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
            case "time": result += now.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
            case "datetime": result += now.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
            case "iso": result += ISO8601DateFormatter().string(from: now)
            case "clipboard": result += clipboard ?? ""
            case "uuid": result += uuid().uuidString
            default: result += rest[open.lowerBound..<close.upperBound]
            }
            rest = after[close.upperBound...]
        }
        return result + rest
    }
}

/// Snippets on disk (`snippets.json`, 0600). Same safety as the notes: a
/// file that fails to parse is never overwritten.
@MainActor
@Observable
final class SnippetStore {
    private(set) var snippets: [Snippet] = []
    var selectedID: Snippet.ID?
    private(set) var isFileBroken = false

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let saves: WriteCoalescer

    init(file: URL = AppPaths.file("snippets.json"), saveDelay: Duration = .milliseconds(800)) {
        self.file = file
        saves = WriteCoalescer(delay: saveDelay)
        if let data = try? Data(contentsOf: file) {
            do {
                snippets = try JSONDecoder.iso.decode([Snippet].self, from: data)
            } catch {
                isFileBroken = true
                Log.storage.error("snippets.json is unreadable; it will not be overwritten")
            }
        }
        selectedID = snippets.first?.id
    }

    var selected: Snippet? { snippets.first { $0.id == selectedID } }

    func add() {
        let snippet = Snippet(id: UUID(), title: "", body: "", edited: Date())
        snippets.insert(snippet, at: 0)
        selectedID = snippet.id
        saveSoon()
    }

    func update(_ id: Snippet.ID, title: String? = nil, body: String? = nil) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        let before = snippets[index]
        if let title { snippets[index].title = title }
        if let body { snippets[index].body = body }
        guard snippets[index] != before else { return }
        snippets[index].edited = Date()
        saveSoon()
    }

    func remove(_ id: Snippet.ID) {
        guard let position = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets.remove(at: position)
        if selectedID == id { selectedID = snippets.indices.contains(position) ? snippets[position].id : snippets.last?.id }
        saveSoon()
    }

    /// Leaving the tab: empty snippets go.
    func sweep() {
        let before = snippets.count
        snippets.removeAll { $0.title.trimmingCharacters(in: .whitespaces).isEmpty && $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if snippets.count != before {
            if selected == nil { selectedID = snippets.first?.id }
            saveSoon()
        }
        flush()
    }

    func flush() { saves.flush() }

    private func saveSoon() {
        saves.schedule { [weak self] in self?.persist() }
    }

    private func persist() {
        guard !isFileBroken else { return }
        do {
            try AppPaths.writePrivate(try JSONEncoder.iso.encode(snippets), to: file)
        } catch {
            Log.storage.error("cannot write snippets.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
