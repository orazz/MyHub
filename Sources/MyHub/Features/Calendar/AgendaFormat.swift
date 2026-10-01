import Foundation

/// Countdown and day labels, as pure functions of a clock and a calendar so
/// they can be tested at any "now".
enum AgendaFormat {
    /// "in 12 min", "in 2 h 5 min", "now · 20 min left". Abbreviated on
    /// purpose: it has to fit the header, and abbreviations need no plurals.
    static func countdown(now: Date, start: Date, end: Date) -> String {
        if start <= now {
            return L10n.format("now · %@ left", duration(end.timeIntervalSince(now)))
        }
        return L10n.format("in %@", duration(start.timeIntervalSince(now)))
    }

    /// Header-sized: "12m", "2h", "now".
    static func shortCountdown(now: Date, start: Date) -> String {
        guard start > now else { return L10n.string("now") }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h" : "\(hours / 24)d"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        if minutes < 60 { return L10n.format("%d min", minutes) }
        let hours = minutes / 60, rest = minutes % 60
        if hours >= 24 { return L10n.format("%d d", hours / 24) }
        return rest == 0 ? L10n.format("%d h", hours) : L10n.format("%d h %d min", hours, rest)
    }

    static func timeRange(_ start: Date, _ end: Date) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return L10n.string("Today") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) {
            return L10n.string("Tomorrow")
        }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    /// "In 20 min · 21:30", or "Now · until 22:00".
    static func nextLine(_ meeting: Meeting, now: Date) -> String {
        let time = meeting.start.formatted(date: .omitted, time: .shortened)
        if meeting.isRunning(at: now) {
            return L10n.format("Now · until %@", meeting.end.formatted(date: .omitted, time: .shortened))
        }
        let calendar = Calendar.current
        if !calendar.isDate(meeting.start, inSameDayAs: now) {
            return "\(dayTitle(meeting.start, now: now)) · \(time)"
        }
        return L10n.format("In %@ · %@", duration(meeting.start.timeIntervalSince(now)), time)
    }

    /// "30m", "1h", "1h 30m".
    static func shortDuration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(minutes)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// The next day that is not a weekend.
    static func nextWorkday(after date: Date, calendar: Calendar = .current) -> Date {
        var day = calendar.startOfDay(for: date)
        repeat {
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        } while calendar.isDateInWeekend(day)
        return day
    }

    struct WeekDay: Identifiable, Equatable {
        var id: Date { date }
        let date: Date
        let letter: String
        let number: Int
        let isToday: Bool
        let isWeekend: Bool
    }

    /// The seven days of the week containing `now`, in the user's own
    /// first-weekday order.
    static func week(of now: Date, calendar: Calendar = .current) -> [WeekDay] {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let letters = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let weekday = calendar.component(.weekday, from: date)
            return WeekDay(date: date, letter: letters[weekday - 1], number: calendar.component(.day, from: date),
                           isToday: calendar.isDate(date, inSameDayAs: now), isWeekend: calendar.isDateInWeekend(date))
        }
    }

    /// Meetings grouped by the day they start on, in order.
    static func byDay(_ meetings: [Meeting], calendar: Calendar = .current) -> [(day: Date, meetings: [Meeting])] {
        var groups: [(day: Date, meetings: [Meeting])] = []
        for meeting in meetings {
            let day = calendar.startOfDay(for: meeting.start)
            if let last = groups.indices.last, groups[last].day == day {
                groups[last].meetings.append(meeting)
            } else {
                groups.append((day, [meeting]))
            }
        }
        return groups
    }
}
