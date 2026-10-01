import Observation

/// Privacy shield for screen sharing and public places: rows in the shielded
/// sections are drawn as a neutral placeholder instead of their text.
///
/// A placeholder rather than a blur, because blurred text still betrays its
/// length and can sometimes be sharpened back. A shielded row stays fully
/// usable — copy, paste and join still work without it being shown.
///
/// Single rows can be *peeked* at with the eye button. Peeks are forgotten
/// as soon as the island folds, so the next opening — the one nobody planned
/// — is shielded again. The choice of sections is saved; peeks never are.
@MainActor
@Observable
final class ContentShield {
    enum Coverage { case none, some, all }

    /// Sections that show personal content and so can be shielded.
    static let eligible: [Section] = [.inbox, .clipboard, .calendar, .notes, .usage, .jira]

    private(set) var shielded: Set<Section>
    private(set) var peeked: Set<String> = []
    @ObservationIgnored private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
        let saved = preferences.values.shieldedSections.compactMap(Section.init(rawValue:))
        shielded = Set(saved.filter(Self.eligible.contains))
    }

    var coverage: Coverage {
        switch shielded.count {
        case 0: .none
        case Self.eligible.count: .all
        default: .some
        }
    }

    func isShielded(_ section: Section) -> Bool { shielded.contains(section) }

    func setShielded(_ on: Bool, for section: Section) {
        guard Self.eligible.contains(section) else { return }
        if on { shielded.insert(section) } else { shielded.remove(section) }
        save()
    }

    func setShieldedEverywhere(_ on: Bool) {
        shielded = on ? Set(Self.eligible) : []
        save()
    }

    /// True when the row `rowID` of `section` must be drawn as a placeholder.
    func masks(_ rowID: String, in section: Section) -> Bool {
        isShielded(section) && !peeked.contains(rowID)
    }

    func togglePeek(_ rowID: String) {
        if peeked.remove(rowID) == nil { peeked.insert(rowID) }
    }

    /// The island folded: every peek ends.
    func endPeeks() {
        if !peeked.isEmpty { peeked = [] }
    }

    private func save() {
        preferences.update { $0.shieldedSections = shielded.map(\.rawValue).sorted() }
        if shielded.isEmpty { peeked = [] }
    }
}
