import Observation
import SwiftUI

/// What the user has typed into a form but not submitted yet.
///
/// The panel's content is rebuilt every time it opens, so text held in a
/// view's `@State` disappears when the island folds — pasting a Jira token,
/// moving the pointer away to copy the next value, and coming back to an
/// empty form. Drafts live here instead, for as long as MyHub runs.
///
/// Memory only, never written to disk: one of these fields is an API token.
/// Each form clears its drafts once they are submitted.
@MainActor
@Observable
final class FormDrafts {
    private var values: [String: String] = [:]

    subscript(key: String) -> String {
        get { values[key] ?? "" }
        set { values[key] = newValue.isEmpty ? nil : newValue }
    }

    func binding(_ key: String) -> Binding<String> {
        Binding(get: { self[key] }, set: { self[key] = $0 })
    }

    /// A yes/no draft, e.g. whether a token field is open.
    func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { self[key] == "1" }, set: { self[key] = $0 ? "1" : "" })
    }

    func clear(_ keys: String...) {
        for key in keys { values[key] = nil }
    }

    /// Sets `key` to `value` unless something was already typed there.
    func seed(_ key: String, _ value: String) {
        if values[key] == nil, !value.isEmpty { values[key] = value }
    }
}
