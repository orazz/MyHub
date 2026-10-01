import AppKit
import EventKit

struct RGBA: Sendable, Equatable {
    var red: Double, green: Double, blue: Double, alpha: Double

    init(_ color: NSColor?) {
        // Catalog colours (.systemBlue, calendar colours) have no components
        // until converted; reading them unconverted throws.
        let c = (color ?? .systemBlue).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
        red = c.redComponent; green = c.greenComponent; blue = c.blueComponent; alpha = c.alphaComponent
    }
}

struct Meeting: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: RGBA
    let calendarTitle: String
    let link: URL?
    let provider: String?
    var location: String? = nil
    var attendees = 0

    func isRunning(at now: Date) -> Bool { start <= now && now < end }
}

struct CalendarInfo: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let source: String
    let color: RGBA
}

/// Owns the `EKEventStore`. EventKit objects are not `Sendable`, so they
/// never leave this actor: everything returned is a plain value snapshot.
/// Fetching runs here, off the main actor.
actor CalendarSource {
    private let store = EKEventStore()
    private var sawAccess = false

    enum Access: Sendable, Equatable { case notDetermined, granted, denied }

    nonisolated static var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Shows the system prompt. Only ever called from the user's button.
    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func calendars() -> [CalendarInfo] {
        guard Self.access == .granted else { return [] }
        refreshIfAccessJustArrived()
        return store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "", color: RGBA($0.color)) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    func meetings(from start: Date, to end: Date, hiddenCalendars: Set<String>) -> [Meeting] {
        guard Self.access == .granted else { return [] }
        refreshIfAccessJustArrived()
        let all = store.calendars(for: .event)
        let calendars = all.filter { !hiddenCalendars.contains($0.calendarIdentifier) }
        // An empty list means "no restriction" to EventKit — every calendar.
        // Hiding them all must show nothing, so stop here.
        guard !calendars.isEmpty else {
            Log.app.info("calendar: \(all.count, privacy: .public) calendars, all hidden")
            return []
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let found = store.events(matching: predicate)
        let kept = found.filter { !$0.isAllDay && $0.status != .canceled && !Self.declinedByMe($0) }
        // Counts only — never titles or details.
        Log.app.debug("""
            calendar: \(all.count, privacy: .public) calendars (\(all.count - calendars.count, privacy: .public) hidden), \
            \(found.count, privacy: .public) events, \(found.filter(\.isAllDay).count, privacy: .public) all-day, \
            \(found.filter { $0.status == .canceled }.count, privacy: .public) cancelled, \
            \(found.filter(Self.declinedByMe).count, privacy: .public) declined → \(kept.count, privacy: .public) shown
            """)
        return kept
            .sorted { $0.startDate < $1.startDate }
            .map(Self.snapshot)
    }

    /// Access granted in System Settings while we were running leaves an
    /// existing store empty until it is reset.
    private func refreshIfAccessJustArrived() {
        guard !sawAccess else { return }
        sawAccess = true
        store.reset()
    }

    private static func declinedByMe(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    private static func snapshot(_ event: EKEvent) -> Meeting {
        let texts = [event.location, event.url?.absoluteString, event.notes].compactMap { $0 }
        let link = CallLinkDetector.find(in: texts)
        // Recurring events share one identifier; the start makes it unique.
        let id = "\(event.eventIdentifier ?? UUID().uuidString)@\(event.startDate.timeIntervalSince1970)"
        return Meeting(
            id: id,
            title: event.title?.isEmpty == false ? event.title : L10n.string("Untitled"),
            start: event.startDate,
            end: event.endDate,
            color: RGBA(event.calendar?.color),
            calendarTitle: event.calendar?.title ?? "",
            link: link,
            provider: link.flatMap(CallLinkDetector.service),
            // A meeting URL in the location field is shown as "Video call".
            location: event.location.flatMap { $0.contains("://") ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 },
            attendees: event.attendees?.count ?? 0
        )
    }
}
