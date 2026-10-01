import AppKit

/// Notices new screenshots in the folder macOS saves them to and hands them
/// to the Stash.
///
/// - The folder is the one set in the Screenshot app (⇧⌘5 → Options), read
///   from `com.apple.screencapture`; the Desktop when unset.
/// - A kqueue-backed `DispatchSource` reports writes to the folder — no
///   polling, nothing runs until a file appears.
/// - A file counts as a screenshot only if macOS tagged it so: `screencapture`
///   sets the `kMDItemIsScreenCapture` metadata attribute on what it saves.
///   Other files landing on the Desktop are ignored.
///
/// Off by default and started only from its switch in Settings: listing the
/// Desktop is what triggers the system's folder-access prompt.
@MainActor
final class ScreenshotWatcher {
    var onScreenshot: ((URL) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var seen: Set<String> = []
    private var folder: URL?
    private var startedAt = Date()

    var isRunning: Bool { source != nil }

    static var screenshotFolder: URL {
        let configured = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        if let configured, !configured.isEmpty {
            let url = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    func start() {
        guard source == nil else { return }
        let folder = Self.screenshotFolder
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.storage.error("cannot watch the screenshot folder")
            return
        }
        self.folder = folder
        startedAt = Date()
        // What is already there is not new.
        seen = Set(Self.listing(folder).map(\.path))
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func folderChanged() {
        guard let folder else { return }
        // `screencapture` writes a hidden file first and renames it; the tag
        // may land a moment later, so look again shortly.
        check(folder)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.check(folder)
        }
    }

    private func check(_ folder: URL) {
        for url in Self.listing(folder) where !seen.contains(url.path) {
            guard Self.isScreenshot(url) else { continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            seen.insert(url.path)
            if created >= startedAt.addingTimeInterval(-2) { onScreenshot?(url) }
        }
    }

    private static func listing(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    /// The attribute `screencapture` puts on its files.
    nonisolated static func isScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }
}

/// Image helpers for stashed screenshots.
enum ImageTools {
    /// The image at half its pixel size — a Retina screenshot as it looks at
    /// 1x — as PNG data.
    static func halfSizePNG(of url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let width = max(1, image.width / 2), height = max(1, image.height / 2)
            guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
        }.value
    }

    /// Copies PNG data as an image, marked so the clipboard history skips it.
    @MainActor
    static func copyPNG(_ png: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(Data(), forType: .myHubOwnWrite)
    }

    /// Opens the image in Preview, where the Markup toolbar annotates it.
    @MainActor
    static func annotate(_ url: URL) {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }
}
