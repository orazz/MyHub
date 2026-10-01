import Foundation

/// Where copied screenshots are saved before they go into the stash:
/// `~/Library/Application Support/MyHub/Captures`. The files are the user's —
/// nothing here deletes them.
enum CaptureFolder {
    static func save(_ png: Data, takenAt date: Date = Date()) async -> URL? {
        let folder = AppPaths.directory("Captures")
        let base = "Capture \(stamp(date))"
        return await Task.detached(priority: .utility) { () -> URL? in
            // "Capture …", then "Capture … 2", "… 3" — the first name not taken.
            let free = (1...).lazy
                .map { n in folder.appendingPathComponent(n == 1 ? "\(base).png" : "\(base) \(n).png") }
                .first { !FileManager.default.fileExists(atPath: $0.path) }
            guard let target = free else { return nil }
            do {
                try AppPaths.writePrivate(png, to: target)
                return target
            } catch {
                Log.storage.error("cannot save capture: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
            timeZone: .current, calendar: .current
        ))
    }
}
