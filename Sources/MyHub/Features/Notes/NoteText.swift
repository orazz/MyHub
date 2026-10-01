import Foundation

/// How a note's plain text is shown: the first line as the title, markdown
/// style `- [ ]` / `- [x]` lines as checkboxes, everything else as text.
/// The text stays the single source of truth; ticking a box rewrites one line.
enum NoteText {
    enum Line: Equatable, Identifiable {
        case task(index: Int, text: String, done: Bool)
        case text(index: Int, text: String)
        case gap(index: Int)

        var id: Int {
            switch self {
            case .task(let index, _, _), .text(let index, _), .gap(let index): index
            }
        }
    }

    /// Lines after the title.
    static func body(of text: String) -> [Line] {
        let lines = text.components(separatedBy: "\n")
        let titleIndex = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? 0
        return lines.enumerated().dropFirst(titleIndex + 1).map { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return .gap(index: index) }
            for (marker, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true), ("* [ ] ", false), ("* [x] ", true)] where line.hasPrefix(marker) {
                return .task(index: index, text: String(line.dropFirst(marker.count)), done: done)
            }
            return .text(index: index, text: line)
        }
    }

    /// The same text with line `index`'s checkbox flipped.
    static func toggling(_ text: String, line index: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return text }
        let line = lines[index]
        if let range = line.range(of: "[ ]") {
            lines[index] = line.replacingCharacters(in: range, with: "[x]")
        } else if let range = line.range(of: "[x]") ?? line.range(of: "[X]") {
            lines[index] = line.replacingCharacters(in: range, with: "[ ]")
        }
        return lines.joined(separator: "\n")
    }

    /// "Just now", "12 min ago", "14:05", "Yesterday", "Mon", "3 Sep".
    static func edited(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return L10n.string("Just now") }
        if seconds < 3600 { return L10n.format("%d min ago", Int(seconds / 60)) }
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return L10n.string("Yesterday") }
        if seconds < 6 * 86400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
