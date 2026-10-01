import Foundation

/// Every finished build MyHub has seen, kept in `build-history.json`.
///
/// Xcode prunes its own build logs over time, and Gradle's daemon logs are
/// cleaned up with the daemons; copying each result here as it is first seen
/// is what lets the statistics reach back a year. Merged by id, so reading
/// the same manifest twice changes nothing. Capped, oldest first out.
struct BuildHistory: Sendable, Equatable, Codable {
    private(set) var records: [BuildRecord] = []
    static let limit = 20_000

    /// Returns true when anything new was added.
    @discardableResult
    mutating func merge(_ incoming: [BuildRecord]) -> Bool {
        let known = Set(records.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) && $0.duration > 0 }
        guard !fresh.isEmpty else { return false }
        records.append(contentsOf: fresh)
        records.sort { $0.finished > $1.finished }
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        return true
    }

    static func load(from file: URL) -> BuildHistory {
        guard let data = try? Data(contentsOf: file),
              let history = try? JSONDecoder.iso.decode(BuildHistory.self, from: data) else { return BuildHistory() }
        return history
    }

    func save(to file: URL) {
        do {
            try AppPaths.writePrivate(try JSONEncoder.iso.encode(self), to: file)
        } catch {
            Log.storage.error("cannot write build-history.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Build-time statistics in the manner of BuildWatch: totals, counts and
/// averages over a range, broken into bars and split by scheme. Pure, so it
/// is tested at any "now".
enum BuildStats {
    enum Range: String, CaseIterable, Sendable {
        case today, week, month, year, all

        var title: String {
            switch self {
            case .today: L10n.string("Today")
            case .week: L10n.string("Week")
            case .month: L10n.string("Month")
            case .year: L10n.string("Year")
            case .all: L10n.string("All")
            }
        }
    }

    enum Metric: String, CaseIterable, Sendable {
        case total, count, average
    }

    struct Bucket: Identifiable, Equatable {
        var id: Date { start }
        let start: Date
        /// Short, for the axis: "Fri", "14", "Sep".
        let label: String
        /// Full, for the hover readout: "Fri 26 Sep", "14:00–15:00", "September 2026".
        var title = ""
        /// Seconds of building per scheme in this bucket.
        var seconds: [String: TimeInterval] = [:]
        var builds = 0
        var failures = 0

        var total: TimeInterval { seconds.values.reduce(0, +) }
        var average: TimeInterval { builds == 0 ? 0 : total / Double(builds) }

        func value(_ metric: Metric) -> Double {
            switch metric {
            case .total: total
            case .count: Double(builds)
            case .average: average
            }
        }
    }

    struct Summary: Equatable {
        var total: TimeInterval = 0
        var builds = 0
        var failures = 0
        var buckets: [Bucket] = []
        /// Schemes by total time, largest first.
        var schemes: [(name: String, seconds: TimeInterval)] = []

        var average: TimeInterval { builds == 0 ? 0 : total / Double(builds) }

        func value(_ metric: Metric) -> Double {
            switch metric {
            case .total: total
            case .count: Double(builds)
            case .average: average
            }
        }

        static func == (a: Summary, b: Summary) -> Bool {
            a.total == b.total && a.builds == b.builds && a.failures == b.failures && a.buckets == b.buckets
                && a.schemes.map(\.name) == b.schemes.map(\.name)
        }
    }

    static func summary(_ records: [BuildRecord], range: Range, now: Date, calendar: Calendar = .current) -> Summary {
        let starts = bucketStarts(range: range, now: now, records: records, calendar: calendar)
        guard let first = starts.first else { return Summary() }
        var buckets = starts.map {
            Bucket(start: $0, label: label($0, range: range, calendar: calendar), title: title($0, range: range, calendar: calendar))
        }
        var summary = Summary()
        var perScheme: [String: TimeInterval] = [:]
        // "All" counts every build in the totals, even ones older than the
        // bars reach back.
        let from = range == .all ? Date.distantPast : first

        for record in records where record.finished >= from && record.finished <= now {
            // A build belongs to the bucket its end falls in — the moment the
            // waiting stopped.
            if let index = starts.lastIndex(where: { $0 <= record.finished }) {
                buckets[index].seconds[record.scheme, default: 0] += record.duration
                buckets[index].builds += 1
                if record.status == .failure { buckets[index].failures += 1 }
            }
            summary.total += record.duration
            summary.builds += 1
            if record.status == .failure { summary.failures += 1 }
            perScheme[record.scheme, default: 0] += record.duration
        }
        summary.buckets = buckets
        summary.schemes = perScheme.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
        return summary
    }

    /// Total build time today — the menu bar figure.
    static func today(_ records: [BuildRecord], now: Date, calendar: Calendar = .current) -> TimeInterval {
        let start = calendar.startOfDay(for: now)
        return records.filter { $0.finished >= start && $0.finished <= now }.map(\.duration).reduce(0, +)
    }

    static func bucketStarts(range: Range, now: Date, records: [BuildRecord], calendar: Calendar = .current) -> [Date] {
        func series(from start: Date, by unit: Calendar.Component, count: Int) -> [Date] {
            (0..<count).compactMap { calendar.date(byAdding: unit, value: $0, to: start) }
        }
        switch range {
        case .today:
            return series(from: calendar.startOfDay(for: now), by: .hour, count: 24)
        case .week:
            let today = calendar.startOfDay(for: now)
            return series(from: calendar.date(byAdding: .day, value: -6, to: today)!, by: .day, count: 7)
        case .month:
            let start = calendar.dateInterval(of: .month, for: now)!.start
            let days = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
            return series(from: start, by: .day, count: days)
        case .year:
            let start = calendar.dateInterval(of: .year, for: now)!.start
            return series(from: start, by: .month, count: 12)
        case .all:
            let thisMonth = calendar.dateInterval(of: .month, for: now)!.start
            let oldest = records.map(\.finished).min().flatMap { calendar.dateInterval(of: .month, for: $0)?.start } ?? thisMonth
            let months = (calendar.dateComponents([.month], from: oldest, to: thisMonth).month ?? 0) + 1
            // At most two years of monthly bars; older builds still count in the totals.
            let shown = min(max(months, 1), 24)
            return series(from: calendar.date(byAdding: .month, value: -(shown - 1), to: thisMonth)!, by: .month, count: shown)
        }
    }

    static func title(_ date: Date, range: Range, calendar: Calendar) -> String {
        switch range {
        case .today:
            let end = calendar.date(byAdding: .hour, value: 1, to: date) ?? date
            let style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute()
            return "\(date.formatted(style))–\(end.formatted(style))"
        case .week, .month: return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .year, .all: return date.formatted(.dateTime.month(.wide).year())
        }
    }

    private static func label(_ date: Date, range: Range, calendar: Calendar) -> String {
        switch range {
        case .today: return date.formatted(.dateTime.hour())
        case .week: return date.formatted(.dateTime.weekday(.abbreviated))
        case .month: return "\(calendar.component(.day, from: date))"
        case .year, .all: return date.formatted(.dateTime.month(.abbreviated))
        }
    }

    /// "35s", "1m 24s", "42m", "1h 12m", "12h". Seconds only while they
    /// matter: a build average of "1m" hides most of the difference.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 600 {
            let rest = total % 60
            return rest == 0 ? "\(total / 60)m" : "\(total / 60)m \(rest)s"
        }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 || hours >= 10 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
