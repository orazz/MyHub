import Foundation

/// Reading the user's Microsoft 365 / Outlook calendar through Microsoft Graph
/// — the path that keeps working now that Exchange Web Services, which macOS
/// Calendar uses for these accounts, is being switched off.
enum MicrosoftCalendar {
    static let color = RGBA(red: 0.36, green: 0.55, blue: 0.95, alpha: 1)

    /// `/me/calendarView` for the next week, oldest first, times in UTC.
    static func calendarViewURL(from start: Date, to end: Date) -> URL? {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/calendarView")
        let iso = ISO8601DateFormatter()
        components?.queryItems = [
            URLQueryItem(name: "startDateTime", value: iso.string(from: start)),
            URLQueryItem(name: "endDateTime", value: iso.string(from: end)),
            URLQueryItem(name: "$select", value: "id,iCalUId,subject,start,end,isAllDay,isCancelled,showAs,location,isOnlineMeeting,onlineMeeting,onlineMeetingProvider,responseStatus,attendees"),
            URLQueryItem(name: "$orderby", value: "start/dateTime"),
            URLQueryItem(name: "$top", value: "100"),
        ]
        return components?.url
    }

    private struct PageDTO: Decodable {
        let value: [Event]
        let nextLink: String?

        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }

        struct Event: Decodable {
            let id: String
            let subject: String?
            let start: Moment
            let end: Moment
            let isAllDay: Bool?
            let isCancelled: Bool?
            let showAs: String?
            let location: Location?
            let isOnlineMeeting: Bool?
            let onlineMeeting: Online?
            let responseStatus: Response?
            let attendees: [Attendee]?
        }
        struct Moment: Decodable { let dateTime: String; let timeZone: String? }
        struct Location: Decodable { let displayName: String? }
        struct Online: Decodable { let joinUrl: String? }
        struct Response: Decodable { let response: String? }
        struct Attendee: Decodable {}
    }

    /// Timed events from one page, and the link to the next page (only if it
    /// is Graph's own). All-day, cancelled and declined events are left out,
    /// as for macOS Calendar.
    static func page(from data: Data) throws -> (meetings: [Meeting], next: URL?) {
        let page = try JSONDecoder().decode(PageDTO.self, from: data)
        let meetings: [Meeting] = page.value.compactMap { event in
            guard event.isAllDay != true, event.isCancelled != true, event.responseStatus?.response != "declined",
                  let start = date(event.start), let end = date(event.end), end > start else { return nil }
            let place = event.location?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            // The Teams link Graph reports, if it passes the same check every
            // Join button does; otherwise a call link written in the location.
            let link = event.onlineMeeting?.joinUrl.flatMap(URL.init(string:)).flatMap { CallLinkDetector.isJoinable($0) ? $0 : nil }
                ?? CallLinkDetector.find(in: [place].compactMap { $0 })
            return Meeting(
                id: "ms-\(event.id)@\(start.timeIntervalSince1970)",
                title: (event.subject?.isEmpty == false ? event.subject : nil) ?? L10n.string("Untitled"),
                start: start, end: end, color: color, calendarTitle: "Microsoft 365",
                link: link, provider: link.flatMap(CallLinkDetector.service),
                location: place.flatMap { $0.isEmpty || $0.contains("://") || $0.lowercased().hasPrefix("microsoft teams") ? nil : $0 },
                attendees: event.attendees?.count ?? 0
            )
        }
        let next = page.nextLink.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host == "graph.microsoft.com" ? $0 : nil }
        return (meetings, next)
    }

    /// Graph's `dateTime` has no zone designator and seven fractional digits
    /// ("2026-10-02T09:00:00.0000000"); with `Prefer: outlook.timezone="UTC"`
    /// it is UTC.
    static func date(_ moment: (dateTime: String, timeZone: String?)) -> Date? {
        guard moment.timeZone == nil || moment.timeZone == "UTC" else { return nil }
        let text = moment.dateTime
        return ISODate.parse(text.hasSuffix("Z") ? text : text + "Z")
    }

    private static func date(_ moment: PageDTO.Moment) -> Date? {
        date((moment.dateTime, moment.timeZone))
    }

    /// The signed-in account, for Settings: name and address.
    static func account(from data: Data) throws -> String {
        struct Me: Decodable { let displayName: String?; let mail: String?; let userPrincipalName: String? }
        let me = try JSONDecoder().decode(Me.self, from: data)
        return [me.displayName, me.mail ?? me.userPrincipalName].compactMap { $0 }.joined(separator: " · ")
    }

    /// One list from macOS Calendar's events and Microsoft's. The same meeting
    /// in both (an Exchange account still syncing in Calendar.app) shows once:
    /// same title, start within a minute — keeping the copy with a join link.
    static func merge(_ local: [Meeting], _ remote: [Meeting]) -> [Meeting] {
        func key(_ meeting: Meeting) -> String { meeting.title.lowercased().trimmingCharacters(in: .whitespaces) }
        var result = local
        for meeting in remote {
            if let index = result.firstIndex(where: { key($0) == key(meeting) && abs($0.start.timeIntervalSince(meeting.start)) < 60 }) {
                if result[index].link == nil, meeting.link != nil { result[index] = meeting }
            } else {
                result.append(meeting)
            }
        }
        return result.sorted { $0.start < $1.start }
    }
}

extension RGBA {
    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}
