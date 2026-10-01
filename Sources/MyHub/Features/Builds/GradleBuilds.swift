import Darwin
import Foundation

/// Gradle builds, from the daemon logs in `~/.gradle/daemon/<version>/`.
///
/// Each build appears as `Received command: Build{id=…, currentDir=<project>…`
/// and ends with `The daemon has finished executing the build.` — verified in
/// this Mac's logs. A start without an end in the log of a daemon that is
/// still running is a build in progress. The logs do not record whether a
/// build succeeded, so finished builds carry an unknown status rather than a
/// guessed one.
enum GradleBuilds {
    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["GRADLE_USER_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gradle")
    }

    static var caches: URL { home.appendingPathComponent("caches") }

    struct Running: Sendable, Equatable {
        let name: String
        let started: Date
    }

    struct LogScan: Sendable, Equatable {
        var finished: [BuildRecord] = []
        var running: Running?
    }

    static func daemonLogs(since: Date) -> [URL] {
        let root = home.appendingPathComponent("daemon")
        let versions = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return versions.flatMap { version -> [URL] in
            let files = (try? FileManager.default.contentsOfDirectory(at: version, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return files.filter { url in
                url.lastPathComponent.hasPrefix("daemon-") && url.pathExtension == "log"
                    && ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) >= since
            }
        }
    }

    /// The daemon's pid, from "daemon-12345.out.log".
    static func pid(ofLog url: URL) -> pid_t? {
        let name = url.lastPathComponent
        guard let start = name.firstIndex(of: "-"), let end = name.firstIndex(of: ".") else { return nil }
        return pid_t(name[name.index(after: start)..<end])
    }

    static func scan(log text: String, file: String, daemonAlive: Bool) -> LogScan {
        var scan = LogScan()
        var open: (id: String, name: String, started: Date)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let range = line.range(of: "Received command: Build{id=") {
                guard let stamp = timestamp(line) else { continue }
                let rest = line[range.upperBound...]
                let id = String(rest.prefix { $0 != "," })
                var name = "Gradle build"
                if let dir = rest.range(of: "currentDir=") {
                    let path = String(rest[dir.upperBound...].prefix { $0 != "," && $0 != "}" })
                    name = projectName(fromDirectory: path)
                }
                open = (id, name, stamp)
            } else if line.contains("The daemon has finished executing the build"), let current = open {
                let end = timestamp(line) ?? current.started
                scan.finished.append(BuildRecord(id: "\(file)#\(current.id)", name: current.name, status: .unknown, started: current.started, finished: end,
                                                  scheme: current.name, platform: .android))
                open = nil
            }
        }
        if let open, daemonAlive, Date().timeIntervalSince(open.started) < 4 * 3600 {
            scan.running = Running(name: open.name, started: open.started)
        }
        return scan
    }

    /// "Orbit" for ".../Orbit/android" or ".../Orbit"; Flutter and React
    /// Native keep the Android project in an `android` subfolder.
    static func projectName(fromDirectory path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let last = url.lastPathComponent
        return ["android", "app"].contains(last.lowercased()) ? url.deletingLastPathComponent().lastPathComponent : last
    }

    /// "2026-09-14T13:13:21.297+0500 [INFO] …"
    static func timestamp<S: StringProtocol>(_ line: S) -> Date? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let stamp = String(line[..<space])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: stamp) { return date }
        // "+0500" rather than "+05:00".
        if stamp.count > 5 {
            let fixed = stamp.dropLast(2) + ":" + stamp.suffix(2)
            return formatter.date(from: String(fixed))
        }
        return nil
    }

    /// Running Gradle daemons, by the pid in their log file names.
    static func daemonPIDs() -> [pid_t] {
        daemonLogs(since: .distantPast).compactMap(pid(ofLog:)).filter { pid in
            ProcessScanner.isAlive(pid) && ProcessScanner.info(pid)?.name == "java"
        }
    }

    /// Asks every daemon to stop (SIGTERM), like `gradle --stop` does.
    static func stopDaemons() -> Int {
        daemonPIDs().filter { kill($0, SIGTERM) == 0 }.count
    }
}
