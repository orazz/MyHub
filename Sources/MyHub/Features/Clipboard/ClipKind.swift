import Foundation
import UniformTypeIdentifiers

/// What a clipboard entry looks like, for its icon and typeface: links,
/// code (monospaced), colours (with a swatch), plain text, files.
enum ClipKind: Equatable, Sendable {
    case link
    case code
    /// Six hex digits, uppercased, without the `#`.
    case color(hex: String)
    case text
    case files(images: Bool)

    var symbol: String {
        switch self {
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .color: "paintpalette"
        case .text: "text.alignleft"
        case .files(let images): images ? "photo" : "doc"
        }
    }

    var isMonospaced: Bool {
        switch self {
        case .code, .color: true
        default: false
        }
    }

    static func classify(_ content: ClipContent) -> ClipKind {
        switch content {
        case .files(let urls):
            let images = !urls.isEmpty && urls.allSatisfy { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            return .files(images: images)
        case .text(let text):
            return classify(text)
        }
    }

    static func classify(_ text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
            return .link
        }
        if let hex = colorHex(trimmed) { return .color(hex: hex) }
        if looksLikeCode(trimmed) { return .code }
        return .text
    }

    /// `#E8A94A`, `#e8a94a80`, `#fa0` (a `#` is required: "facade" is a word).
    static func colorHex(_ text: String) -> String? {
        guard text.hasPrefix("#") else { return nil }
        let digits = text.dropFirst()
        guard digits.allSatisfy(\.isHexDigit), [3, 6, 8].contains(digits.count) else { return nil }
        let six = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : String(digits.prefix(6))
        return six.uppercased()
    }

    private static let shellStarts = ["$ ", "sudo ", "rm ", "cd ", "git ", "npm ", "npx ", "yarn ", "brew ", "ls ", "cat ", "curl ",
                                      "swift ", "xcodebuild", "xcrun ", "./", "~/", "docker ", "kubectl ", "pip ", "python ", "grep "]
    private static let codeMarkers = ["{", "};", "=>", "->", "func ", "let ", "const ", "var ", "import ", "def ", "class ",
                                      "return ", "</", "#include", "&&", "||", "()"]

    static func looksLikeCode(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        if shellStarts.contains(where: { lower.hasPrefix($0) }) { return true }
        if text.hasPrefix("/"), !text.contains(" ") { return true }
        let lines = text.split(separator: "\n")
        if lines.count > 1, lines.dropFirst().contains(where: { $0.hasPrefix("    ") || $0.hasPrefix("\t") }) { return true }
        let hits = codeMarkers.filter { text.contains($0) }.count
        return hits >= 2 || (hits == 1 && text.count < 120 && text.hasSuffix(";"))
    }
}

enum ClipFormat {
    /// "now", "4m", "12m", "1h", "3d".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return L10n.string("now")
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }
}
