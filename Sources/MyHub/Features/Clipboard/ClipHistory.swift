import Foundation

enum ClipContent: Codable, Equatable, Sendable {
    case text(String)
    case files([URL])
}

struct ClipEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var content: ClipContent
    var date: Date
    var pinned: Bool
    /// Name of the app that was frontmost when the copy happened, if known.
    var source: String?

    var preview: String {
        switch content {
        case .text(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
        case .files(let urls):
            let first = urls.first?.lastPathComponent ?? ""
            return urls.count > 1 ? "\(first) +\(urls.count - 1)" : first
        }
    }

    var kind: ClipKind { ClipKind.classify(content) }

    var symbol: String { kind.symbol }
}

/// The ordered list and its rules, with no pasteboard in sight — so every
/// rule is a unit test.
///
/// Newest first. Copying something already in the list moves it to the top
/// instead of duplicating it. Pinned entries survive the limit and "Clear";
/// they are the things you meant to keep.
struct ClipHistory: Codable, Equatable, Sendable {
    private(set) var entries: [ClipEntry] = []
    var limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var pinned: [ClipEntry] { entries.filter(\.pinned) }
    var recent: [ClipEntry] { entries.filter { !$0.pinned } }

    mutating func record(_ content: ClipContent, at date: Date, source: String?) {
        if let index = entries.firstIndex(where: { $0.content == content }) {
            var existing = entries.remove(at: index)
            existing.date = date
            existing.source = source ?? existing.source
            entries.insert(existing, at: 0)
        } else {
            entries.insert(ClipEntry(id: UUID(), content: content, date: date, pinned: false, source: source), at: 0)
        }
        trim()
    }

    /// Freshly re-used entries rise to the top.
    mutating func promote(_ id: UUID, at date: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.date = date
        entries.insert(entry, at: 0)
    }

    mutating func togglePin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].pinned.toggle()
        trim()
    }

    mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    mutating func clearUnpinned() {
        entries.removeAll { !$0.pinned }
    }

    mutating func setLimit(_ limit: Int) {
        self.limit = max(1, limit)
        trim()
    }

    /// Oldest unpinned go first; pinned entries never count against the limit.
    private mutating func trim() {
        while entries.filter({ !$0.pinned }).count > limit,
              let index = entries.lastIndex(where: { !$0.pinned }) {
            entries.remove(at: index)
        }
    }
}
