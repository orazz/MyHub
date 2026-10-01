import Foundation

/// Xcode builds, read from what Xcode itself leaves behind.
///
/// - **Finished builds**: `DerivedData/<Project>-<hash>/Logs/Build/LogStoreManifest.plist`
///   lists every build with its title ("Building workspace Runner with scheme
///   Runner and configuration Debug"), start and stop times (seconds since
///   2001), and `primaryObservable.highLevelStatus` (S success, W warnings,
///   E errors). Verified against this Mac's DerivedData.
/// - **A build in progress**: compiler processes (swift-frontend, clang, ld…)
///   whose ancestry includes Xcode's build service or `xcodebuild`. Xcode
///   publishes no progress while building, so the bar is time against the
///   average of that project's recent builds, and says so.
enum XcodeBuilds {
    static var derivedData: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    static let buildServices: Set<String> = ["XCBBuildService", "SWBBuildService", "xcodebuild"]
    static let buildTools: Set<String> = ["swift-frontend", "swiftc", "swift-driver", "clang", "ld", "ld64", "actool", "ibtool", "libtool", "swift-build"]

    // MARK: - Finished builds

    static func recentBuilds(in root: URL = derivedData, limit: Int = 4) -> [BuildRecord] {
        let projects = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return projects
            .flatMap { records(fromManifestAt: $0.appendingPathComponent("Logs/Build/LogStoreManifest.plist")) }
            .sorted { $0.finished > $1.finished }
            .prefix(limit)
            .map { $0 }
    }

    static func records(fromManifestAt url: URL) -> [BuildRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return records(fromManifest: data)
    }

    static func records(fromManifest data: Data) -> [BuildRecord] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let logs = plist["logs"] as? [String: [String: Any]] else { return [] }
        return logs.compactMap { key, entry in
            guard let start = (entry["timeStartedRecording"] as? NSNumber)?.doubleValue,
                  let stop = (entry["timeStoppedRecording"] as? NSNumber)?.doubleValue else { return nil }
            let title = entry["title"] as? String ?? ""
            // A clean is not build time; counting it would skew the averages.
            if title.hasPrefix("Clean") { return nil }
            let scheme = entry["schemeIdentifier-schemeName"] as? String
            let observable = entry["primaryObservable"] as? [String: Any]
            let status: BuildRecord.Status
            switch observable?["highLevelStatus"] as? String {
            case "S", "W": status = .success
            case "E": status = .failure
            case "A": status = .cancelled
            default: status = (observable?["totalNumberOfErrors"] as? NSNumber)?.intValue ?? 0 > 0 ? .failure : .unknown
            }
            return BuildRecord(
                id: key,
                name: displayName(title: title, scheme: scheme),
                status: status,
                started: Date(timeIntervalSinceReferenceDate: start),
                finished: Date(timeIntervalSinceReferenceDate: stop),
                scheme: scheme,
                platform: .xcode
            )
        }
    }

    /// "Orbit · Debug" from "Building workspace Orbit with scheme Orbit and
    /// configuration Debug"; the scheme alone when the title says nothing more.
    static func displayName(title: String, scheme: String?) -> String {
        let base = scheme ?? title
        if let range = title.range(of: "configuration ") {
            let configuration = title[range.upperBound...].split(separator: " ").first.map(String.init)
            if let configuration { return "\(base) · \(configuration)" }
        }
        return base
    }

    // MARK: - In progress

    /// Build-tool processes working for Xcode right now.
    static func activeJobs(in processes: [ProcessScanner.Info]) -> [ProcessScanner.Info] {
        let table = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        return processes.filter { process in
            if process.name == "xcodebuild" { return true }
            guard buildTools.contains(process.name) else { return false }
            return ProcessScanner.ancestors(of: process.pid, in: table).contains { buildServices.contains($0) }
        }
    }

    /// The project whose build products changed most recently — the one
    /// being built. "Orbit" from "Orbit-abcdefghij".
    static func activeProject(in root: URL = derivedData) -> String? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let projects = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? []
        let newest = projects
            .filter { !$0.lastPathComponent.hasSuffix(".noindex") }
            .compactMap { url -> (URL, Date)? in
                let build = url.appendingPathComponent("Build")
                let date = (try? build.resourceValues(forKeys: keys))?.contentModificationDate
                    ?? (try? url.resourceValues(forKeys: keys))?.contentModificationDate
                return date.map { (url, $0) }
            }
            .max { $0.1 < $1.1 }
        return newest.map { projectName(fromFolder: $0.0.lastPathComponent) }
    }

    static func projectName(fromFolder folder: String) -> String {
        guard let dash = folder.lastIndex(of: "-") else { return folder }
        let suffix = folder[folder.index(after: dash)...]
        return suffix.count >= 20 && suffix.allSatisfy(\.isLowercase) ? String(folder[..<dash]) : folder
    }

    // MARK: - Clearing

    /// Deletes everything inside DerivedData, never the folder itself and
    /// never anything outside it. Xcode rebuilds what it needs.
    static func clear(root: URL = derivedData) async -> Int {
        await Task.detached(priority: .utility) {
            let expected = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/DerivedData").standardizedFileURL
            guard root.standardizedFileURL == expected || root.path.hasPrefix(NSTemporaryDirectory()) else { return 0 }
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            var removed = 0
            for child in children where child.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL {
                if (try? FileManager.default.removeItem(at: child)) != nil { removed += 1 }
            }
            return removed
        }.value
    }
}
