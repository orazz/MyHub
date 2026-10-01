import CryptoKit
import Foundation

/// Developer transforms for a copied piece of text: format JSON, look inside
/// a JWT, Base64 and URL coding, timestamps, hashes, a fresh UUID.
///
/// Pure functions, run locally. A JWT is only decoded for reading — its
/// signature is never checked and it never leaves the Mac.
enum TextTool: String, CaseIterable, Identifiable, Sendable {
    case formatJSON, minifyJSON, decodeJWT, base64Decode, base64Encode, urlDecode, urlEncode
    case timestamp, sha256, md5, uuid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .formatJSON: L10n.string("Format JSON")
        case .minifyJSON: L10n.string("Minify")
        case .decodeJWT: L10n.string("Decode JWT")
        case .base64Decode: L10n.string("Base64 decode")
        case .base64Encode: L10n.string("Base64")
        case .urlDecode: L10n.string("URL decode")
        case .urlEncode: L10n.string("URL encode")
        case .timestamp: L10n.string("Timestamp")
        case .sha256: "SHA-256"
        case .md5: "MD5"
        case .uuid: L10n.string("New UUID")
        }
    }

    var symbol: String {
        switch self {
        case .formatJSON, .minifyJSON: "curlybraces"
        case .decodeJWT: "key"
        case .base64Decode, .base64Encode: "textformat.abc"
        case .urlDecode, .urlEncode: "link"
        case .timestamp: "clock"
        case .sha256, .md5: "number"
        case .uuid: "dice"
        }
    }

    /// Texts longer than this are only offered the hashes: the other tools
    /// are for snippets, and a megabyte of JSON doesn't belong in the panel.
    static let maxInput = 256 * 1024

    /// The tools that make sense for `text`, most specific first. A new UUID
    /// is always offered.
    static func suggestions(for text: String) -> [TextTool] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [.uuid] }
        guard text.utf8.count <= maxInput else { return [.sha256, .uuid] }
        var tools: [TextTool] = []
        if JWT.parts(trimmed) != nil { tools.append(.decodeJWT) }
        if JSONText.isJSON(trimmed) {
            tools += [.formatJSON, .minifyJSON]
        }
        if Timestamp.describe(trimmed) != nil { tools.append(.timestamp) }
        if trimmed.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil { tools.append(.urlDecode) }
        if !tools.contains(.decodeJWT), Base64Text.decode(trimmed) != nil { tools.append(.base64Decode) }
        tools += [.base64Encode, .urlEncode, .sha256, .md5, .uuid]
        return tools
    }

    /// The result, or nil when the tool doesn't apply to this text.
    func apply(to text: String, now: Date = Date()) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .formatJSON: return JSONText.reformat(trimmed, pretty: true)
        case .minifyJSON: return JSONText.reformat(trimmed, pretty: false)
        case .decodeJWT: return JWT.describe(trimmed, now: now)
        case .base64Decode: return Base64Text.decode(trimmed)
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .urlDecode: return trimmed.removingPercentEncoding
        case .urlEncode: return text.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)
        case .timestamp: return Timestamp.describe(trimmed)
        case .sha256: return SHA256.hash(data: Data(text.utf8)).hex
        case .md5: return Insecure.MD5.hash(data: Data(text.utf8)).hex
        case .uuid: return UUID().uuidString
        }
    }
}

enum JSONText {
    static func isJSON(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[" else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil
    }

    static func reformat(_ text: String, pretty: Bool) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else { return nil }
        var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .fragmentsAllowed]
        if pretty { options.formUnion([.prettyPrinted, .sortedKeys]) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

enum Base64Text {
    /// Standard or URL-safe Base64, padded or not, that decodes to UTF-8 text.
    /// Short or plainly non-Base64 strings are refused, so ordinary words are
    /// not mistaken for it.
    static func decode(_ text: String) -> String? {
        guard text.count >= 8, text.range(of: "^[A-Za-z0-9+/_-]+={0,2}$", options: .regularExpression) != nil else { return nil }
        var normalized = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized), let string = String(data: data, encoding: .utf8),
              !string.contains("\u{0}") else { return nil }
        return string
    }
}

enum JWT {
    /// Header and payload, when `text` is three dot-separated Base64URL parts
    /// whose first two are JSON objects.
    static func parts(_ text: String) -> (header: [String: Any], payload: [String: Any])? {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, text.count < 16 * 1024,
              let header = object(String(pieces[0])), header["alg"] != nil,
              let payload = object(String(pieces[1])) else { return nil }
        return (header, payload)
    }

    private static func object(_ part: String) -> [String: Any]? {
        guard let json = Base64Text.decode(part) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// Header and claims as formatted JSON, plus what the time claims mean.
    static func describe(_ text: String, now: Date) -> String? {
        guard let (header, payload) = parts(text) else { return nil }
        func pretty(_ object: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        var lines = ["// header", pretty(header), "// payload", pretty(payload)]
        for (claim, label) in [("iat", "issued"), ("nbf", "valid from"), ("exp", "expires")] {
            guard let seconds = (payload[claim] as? NSNumber)?.doubleValue else { continue }
            let date = Date(timeIntervalSince1970: seconds)
            let relative = date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
            lines.append("// \(label): \(date.formatted(.iso8601)) (\(relative))")
        }
        if let exp = (payload["exp"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: exp) < now {
            lines.append("// expired")
        }
        lines.append("// signature not verified")
        return lines.joined(separator: "\n")
    }
}

enum Timestamp {
    /// A Unix time in seconds (10 digits) or milliseconds (13) becomes an ISO
    /// date in UTC and local time; an ISO date becomes Unix seconds.
    static func describe(_ text: String) -> String? {
        if text.range(of: "^[0-9]{10}$|^[0-9]{13}$", options: .regularExpression) != nil, let value = Double(text) {
            let date = Date(timeIntervalSince1970: text.count == 13 ? value / 1000 : value)
            let utc = ISO8601DateFormatter().string(from: date)
            let here = date.formatted(date: .abbreviated, time: .standard)
            return "\(utc)\n\(here) (\(TimeZone.current.identifier))"
        }
        if let date = ISODate.parse(text) {
            return String(Int64(date.timeIntervalSince1970.rounded()))
        }
        return nil
    }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension CharacterSet {
    /// Unreserved characters only (RFC 3986), so the result is safe as a
    /// query value: `&`, `=`, `+`, `/` and `?` are all escaped.
    static let urlQueryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
