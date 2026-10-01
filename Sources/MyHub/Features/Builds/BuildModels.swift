import Foundation

struct BuildRecord: Identifiable, Sendable, Equatable, Codable {
    enum Status: String, Sendable, Equatable, Codable {
        case success, failure, cancelled
        /// Gradle's daemon logs say when a build ran, not how it ended.
        case unknown
    }

    enum Platform: String, Sendable, Equatable, Codable {
        case xcode, android
    }

    let id: String
    /// "Orbit · Debug" — scheme and configuration, for display.
    let name: String
    let status: Status
    let started: Date
    let finished: Date
    /// The scheme (Xcode) or project (Gradle) — what stats group by.
    let scheme: String
    let platform: Platform

    init(id: String, name: String, status: Status, started: Date, finished: Date,
         scheme: String? = nil, platform: Platform = .xcode) {
        self.id = id
        self.name = name
        self.status = status
        self.started = started
        self.finished = finished
        self.scheme = scheme ?? name.components(separatedBy: " · ").first ?? name
        self.platform = platform
    }

    var duration: TimeInterval { max(0, finished.timeIntervalSince(started)) }
}

struct CurrentBuild: Sendable, Equatable {
    let target: String
    let detail: String
    let startedAt: Date
    /// Typical duration for this target, from its recent builds.
    let averageDuration: TimeInterval?
    let step: String
}

enum BuildFormat {
    /// "0:42", "12:05", "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// Folder sizes, computed off the main actor — DerivedData is often tens of
/// gigabytes over hundreds of thousands of files.
enum FolderSize {
    static func of(_ url: URL) async -> Int64? {
        await Task.detached(priority: .utility) { measure(url) }.value
    }

    static func measure(_ url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
