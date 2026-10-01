/// A value that must never be printed.
///
/// String interpolation, `print`, `dump`, `Logger` and error descriptions all
/// go through `description`/`Mirror`, and every one of them sees a placeholder.
/// Reaching the real value takes an explicit `.exposed`, which keeps every use
/// easy to find with a search. Deliberately not `Codable`: a secret that can be
/// encoded will eventually be encoded into the wrong file.
struct Redacted<Value: Sendable>: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let exposed: Value

    init(_ value: Value) {
        exposed = value
    }

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var customMirror: Mirror { Mirror(self, children: []) }
}

extension Redacted: Equatable where Value: Equatable {}

extension Redacted where Value == String {
    /// What a settings row may show: the last four characters of a long key,
    /// nothing at all of a short one.
    var hint: String {
        exposed.count >= 12 ? "••••" + exposed.suffix(4) : "••••"
    }

    var isEmpty: Bool { exposed.isEmpty }
}
