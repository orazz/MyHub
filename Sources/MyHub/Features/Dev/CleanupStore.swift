import AppKit
import Observation

/// A place where Xcode and its tools pile up data, and how to reclaim it.
struct CleanupTarget: Identifiable, Sendable {
    enum Action: Sendable {
        /// Delete everything inside the folders (they are rebuilt on demand).
        case deleteContents
        /// Move everything inside to the Trash (worth a second look first).
        case trashContents
        /// `xcrun simctl delete unavailable`: devices whose runtime is gone.
        case deleteUnavailableSimulators
    }

    let id: String
    let title: String
    let detail: String
    let folders: [URL]
    let action: Action

    static let all: [CleanupTarget] = {
        let developer = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer")
        let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        let xcode = developer.appendingPathComponent("Xcode")
        return [
            CleanupTarget(id: "derived", title: "DerivedData", detail: L10n.string("Build products and indexes; rebuilt on the next build"),
                          folders: [xcode.appendingPathComponent("DerivedData")], action: .deleteContents),
            CleanupTarget(id: "devicesupport", title: L10n.string("Device support"), detail: L10n.string("Symbols copied from devices; fetched again when a device connects"),
                          folders: ["iOS", "watchOS", "tvOS", "xrOS", "visionOS"].map { xcode.appendingPathComponent("\($0) DeviceSupport") },
                          action: .deleteContents),
            CleanupTarget(id: "simdevices", title: L10n.string("Simulators"), detail: L10n.string("Removes devices whose runtime is no longer installed"),
                          folders: [developer.appendingPathComponent("CoreSimulator/Devices")], action: .deleteUnavailableSimulators),
            CleanupTarget(id: "simcaches", title: L10n.string("Simulator caches"), detail: L10n.string("Dyld and runtime caches; rebuilt on boot"),
                          folders: [developer.appendingPathComponent("CoreSimulator/Caches")], action: .deleteContents),
            CleanupTarget(id: "previews", title: L10n.string("SwiftUI previews"), detail: L10n.string("Preview simulators and builds"),
                          folders: [xcode.appendingPathComponent("UserData/Previews")], action: .deleteContents),
            CleanupTarget(id: "xcodecache", title: L10n.string("Xcode caches"), detail: L10n.string("Downloaded and generated caches"),
                          folders: [caches.appendingPathComponent("com.apple.dt.Xcode")], action: .deleteContents),
            CleanupTarget(id: "swiftpm", title: L10n.string("Swift packages"), detail: L10n.string("Cached package checkouts; downloaded again when needed"),
                          folders: [caches.appendingPathComponent("org.swift.swiftpm")], action: .deleteContents),
            CleanupTarget(id: "archives", title: L10n.string("Archives"), detail: L10n.string("Shipped builds and their dSYMs — moved to the Trash, not deleted"),
                          folders: [xcode.appendingPathComponent("Archives")], action: .trashContents),
        ]
    }()

    /// Only ever these folders' *children* are removed, and only when they
    /// are inside ~/Library — a defence against a target list edited wrong.
    var isSafe: Bool {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").standardizedFileURL.path + "/"
        return folders.allSatisfy { $0.standardizedFileURL.path.hasPrefix(library) }
    }
}

/// The Cleanup page: how much each Xcode data folder takes, and a two-step
/// button to reclaim it. Sizes are measured when the page is shown (at most
/// every ten minutes) — walking these folders reads hundreds of thousands of
/// entries, so it is never done in the background.
@MainActor
@Observable
final class CleanupStore {
    private(set) var sizes: [String: Int64] = [:]
    private(set) var measuring: Set<String> = []
    private(set) var cleaning: String?
    var confirming: String?
    private(set) var reclaimed: Int64 = 0

    @ObservationIgnored private var measuredAt = Date.distantPast
    @ObservationIgnored private var measureTask: Task<Void, Never>?

    let targets = CleanupTarget.all

    var total: Int64 { sizes.values.reduce(0, +) }

    func pageShown() {
        confirming = nil
        if Date().timeIntervalSince(measuredAt) > 600 { measure() }
    }

    func measure() {
        measureTask?.cancel()
        measuredAt = Date()
        measuring = Set(targets.map(\.id))
        let targets = self.targets
        measureTask = Task { [weak self] in
            await withTaskGroup(of: (String, Int64).self) { group in
                for target in targets {
                    group.addTask {
                        var bytes: Int64 = 0
                        for folder in target.folders { bytes += await FolderSize.of(folder) ?? 0 }
                        return (target.id, bytes)
                    }
                }
                for await (id, bytes) in group {
                    guard let self, !Task.isCancelled else { return }
                    self.sizes[id] = bytes
                    self.measuring.remove(id)
                }
            }
        }
    }

    #if DEBUG
    func injectForPreview(_ sizes: [String: Int64]) { self.sizes = sizes }
    #endif

    func reveal(_ target: CleanupTarget) {
        let existing = target.folders.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
    }

    func clean(_ target: CleanupTarget) {
        confirming = nil
        guard target.isSafe, cleaning == nil else { return }
        cleaning = target.id
        let before = sizes[target.id] ?? 0
        Task { [weak self] in
            switch target.action {
            case .deleteUnavailableSimulators:
                _ = try? await CommandRunner.run(SimulatorStore.xcrun, ["simctl", "delete", "unavailable"], timeout: .seconds(300))
            case .deleteContents, .trashContents:
                await Task.detached(priority: .utility) { Self.empty(target) }.value
            }
            var after: Int64 = 0
            for folder in target.folders { after += await FolderSize.of(folder) ?? 0 }
            guard let self else { return }
            sizes[target.id] = after
            reclaimed += max(0, before - after)
            cleaning = nil
        }
    }

    nonisolated private static func empty(_ target: CleanupTarget) {
        let fm = FileManager.default
        for folder in target.folders {
            let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for child in children where child.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                switch target.action {
                case .trashContents: try? fm.trashItem(at: child, resultingItemURL: nil)
                default: try? fm.removeItem(at: child)
                }
            }
        }
    }
}
