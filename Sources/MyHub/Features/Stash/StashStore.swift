import AppKit
import Observation
import UniformTypeIdentifiers

struct StashItem: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    /// Where the file was last seen. The bookmark is the source of truth.
    var url: URL
    /// A minimal bookmark follows the file through renames and moves, which a
    /// stored path does not.
    var bookmark: Data
    let added: Date
    /// Bytes on disk, when known (nil for folders and unreadable files).
    var size: Int64?

    var name: String { url.lastPathComponent }

    var isImage: Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) ?? false
    }

    /// SF Symbol for the file's kind, used until a preview renders.
    var symbol: String {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if url.hasDirectoryPath || url.pathExtension.isEmpty && size == nil { return "folder" }
        guard let type else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// Files held for later. Referenced, never copied: the stash is a waiting
/// area, and deleting the original takes the card with it.
///
/// **No disk access at launch.** The list loads from `stash.json` and icons
/// come from file extensions alone. Touching a file inside Desktop, Documents
/// or Downloads raises a privacy prompt, and a prompt at login with nothing on
/// screen to explain it is an interruption. Bookmarks are resolved, missing
/// files pruned and previews rendered in `refresh()`, when the stash is shown.
@MainActor
@Observable
final class StashStore {
    private(set) var items: [StashItem] = []
    /// Cards picked for a group drag or copy.
    private(set) var selection: Set<UUID> = []
    private(set) var previews: [UUID: NSImage] = [:]
    /// A drag out of the stash is in flight; the island stays open for it.
    var isDraggingOut = false

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private let rendersPreviews: Bool
    @ObservationIgnored private var previewTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var typeIcons: [String: NSImage] = [:]

    init(file: URL = AppPaths.file("stash.json", formerly: "shelf.json"), limit: Int = 60, rendersPreviews: Bool = true) {
        self.file = file
        self.limit = limit
        self.rendersPreviews = rendersPreviews
        load()
    }

    // MARK: - Adding and removing

    /// Newest first, in the order they were dropped. A file already in the
    /// stash moves to the front instead of appearing twice.
    func add(_ urls: [URL]) {
        var added: [StashItem] = []
        for url in urls.map(\.standardizedFileURL).reversed() {
            if let index = items.firstIndex(where: { $0.url == url }) {
                items.insert(items.remove(at: index), at: 0)
                continue
            }
            do {
                let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                let item = StashItem(id: UUID(), url: url, bookmark: bookmark, added: Date(), size: Self.fileSize(url))
                items.insert(item, at: 0)
                added.append(item)
            } catch {
                Log.storage.error("cannot bookmark a stash file: \(error.localizedDescription, privacy: .public)")
            }
        }
        if items.count > limit {
            let dropped = items[limit...].map(\.id)
            items.removeLast(items.count - limit)
            forget(Set(dropped))
        }
        persist()
        added.forEach(loadPreview)
    }

    /// Sum of the known sizes.
    var totalBytes: Int64 { items.compactMap(\.size).reduce(0, +) }

    nonisolated static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]), values.isDirectory != true else { return nil }
        return values.fileSize.map(Int64.init)
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        forget([id])
        persist()
    }

    func clear() {
        forget(Set(items.map(\.id)))
        items.removeAll()
        persist()
    }

    private func forget(_ ids: Set<UUID>) {
        selection.subtract(ids)
        for id in ids {
            previewTasks.removeValue(forKey: id)?.cancel()
            previews.removeValue(forKey: id)
        }
    }

    // MARK: - Refresh from disk

    /// Called when the stash comes into view; cheap to call often.
    func refreshIfStale() {
        guard refreshTask == nil, Date().timeIntervalSince(lastRefresh) > 3 else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            self?.lastRefresh = Date()
            self?.refreshTask = nil
        }
    }

    enum Resolution: Sendable, Equatable {
        case present(URL, refreshedBookmark: Data?, size: Int64?)
        case gone
        /// Exists, but we may not look (privacy denial, unmounted volume).
        /// Such a card stays: one "Don't Allow" must not empty the stash.
        case unreachable
    }

    /// Resolves every bookmark off the main actor, then applies the results
    /// to whatever the list looks like by then — it may have changed while
    /// we were away, so results are matched by id, never by position.
    func refresh() async {
        let snapshot = items
        guard !snapshot.isEmpty else { return }
        let results = await Task.detached(priority: .utility) {
            snapshot.map { ($0.id, Self.resolve($0)) }
        }.value

        var gone: Set<UUID> = []
        var changed = false
        for (id, resolution) in results {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            switch resolution {
            case .gone:
                gone.insert(id)
            case .present(let url, let fresh, let size):
                if items[index].url != url { items[index].url = url; changed = true }
                if let fresh { items[index].bookmark = fresh; changed = true }
                if items[index].size != size { items[index].size = size; changed = true }
            case .unreachable:
                break
            }
        }
        if !gone.isEmpty {
            items.removeAll { gone.contains($0.id) }
            forget(gone)
            changed = true
        }
        if changed { persist() }
        items.forEach(loadPreview)
    }

    nonisolated static func resolve(_ item: StashItem) -> Resolution {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: item.bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            return isMissing(error) ? .gone : .unreachable
        }
        do {
            guard try url.checkResourceIsReachable() else { return .gone }
        } catch {
            return isMissing(error) ? .gone : .unreachable
        }
        let fresh = stale ? try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        return .present(url, refreshedBookmark: fresh, size: fileSize(url))
    }

    private nonisolated static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }

    // MARK: - Icons

    func icon(for item: StashItem) -> NSImage {
        if let preview = previews[item.id] { return preview }
        let ext = item.url.pathExtension.lowercased()
        if let cached = typeIcons[ext] { return cached }
        // From the extension alone — asking for the file's own icon reads it.
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        typeIcons[ext] = icon
        return icon
    }

    private func loadPreview(for item: StashItem) {
        guard rendersPreviews, previews[item.id] == nil, previewTasks[item.id] == nil else { return }
        let id = item.id
        let url = item.url
        previewTasks[id] = Task { [weak self] in
            let thumbnail = await ThumbnailLoader.thumbnail(for: url, side: 112)
            guard let self, !Task.isCancelled else { return }
            self.previewTasks[id] = nil
            if let thumbnail {
                self.previews[id] = NSImage(cgImage: thumbnail.image, size: thumbnail.size)
            }
        }
    }

    // MARK: - Selection

    /// Without `extending`, a click makes `id` the only selected card, or
    /// clears it if it already was. With it (⌘ or ⇧ held), `id` joins or
    /// leaves the current selection.
    func select(_ id: UUID, extending: Bool) {
        if extending {
            selection.formSymmetricDifference([id])
        } else {
            selection = selection == [id] ? [] : [id]
        }
    }

    func isSelected(_ id: UUID) -> Bool { selection.contains(id) }

    func clearSelection() { selection.removeAll() }

    /// A drag carries the whole selection when it starts on a selected card,
    /// otherwise just the card under the pointer.
    func dragURLs(startingAt id: UUID) -> [URL] {
        let ids = selection.contains(id) ? selection : [id]
        return items.filter { ids.contains($0.id) }.map(\.url)
    }

    // MARK: - Actions

    /// One pasteboard item per file — a file URL for Finder and other apps
    /// that take files, its path as text for everything else — each tagged
    /// as MyHub's own so the clipboard history skips it.
    func copy(_ ids: Set<UUID>) {
        let copied: [NSPasteboardItem] = items.lazy.filter { ids.contains($0.id) }.map { item in
            let entry = NSPasteboardItem()
            entry.setString(item.url.absoluteString, forType: .fileURL)
            entry.setString(item.url.path, forType: .string)
            entry.setData(Data(), forType: .myHubOwnWrite)
            return entry
        }
        if copied.isEmpty { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(copied)
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ ids: Set<UUID>) {
        let urls = items.filter { ids.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            items = try JSONDecoder().decode([StashItem].self, from: data)
        } catch {
            Log.storage.error("stash.json is unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            try AppPaths.writePrivate(try JSONEncoder().encode(items), to: file)
        } catch {
            Log.storage.error("cannot write stash.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
