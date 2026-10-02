import AppKit
import Observation

/// Figma in the Inbox: comments, @mentions, replies in the user's threads
/// and named versions on the files they chose to watch.
///
/// Figma's API can't list "my files", so the user pastes links (up to
/// `maxFiles`). Comment and version calls are rate-limited per seat — as few
/// as 5 a minute on a View seat — so the files are checked at most every
/// 5 minutes, only when the Inbox refreshes, and a 429 pauses checking for
/// as long as Figma asks.
@MainActor
@Observable
final class FigmaStore {
    enum Connection: Equatable { case disconnected, connected, expired }

    private(set) var connection: Connection
    private(set) var me: FigmaUser?
    private(set) var items: [InboxItem] = []
    private(set) var problem: String?
    private(set) var isConnecting = false

    /// A new mention, reply or version since the last check.
    @ObservationIgnored var onNew: ((InboxItem) -> Void)?

    static let maxFiles = 10
    static let minInterval: TimeInterval = 300
    static let window: TimeInterval = 7 * 86400

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var lastChecked = Date.distantPast
    @ObservationIgnored private var pausedUntil = Date.distantPast
    @ObservationIgnored private var known: Set<String>?

    init(preferences: Preferences) {
        self.preferences = preferences
        connection = FigmaClient.storedToken() == nil ? .disconnected : .connected
    }

    var settings: Preferences.Figma { preferences.values.figma }
    var files: [Preferences.Figma.File] { settings.files }

    private func client() -> FigmaClient? { FigmaClient.storedToken().map(FigmaClient.init) }

    // MARK: - Connecting

    /// Checks the token with `/v1/me` before keeping it.
    @discardableResult
    func connect(token raw: String) async -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !isConnecting else { return false }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let user = try await FigmaClient(token: Redacted(token)).me()
            try Keychain.store(Redacted(token), account: FigmaClient.keychainAccount)
            me = user
            connection = .connected
            problem = nil
            lastChecked = .distantPast
            return true
        } catch UsageError.unauthorized {
            problem = L10n.string("Figma refused the token. It needs the current_user:read scope.")
        } catch {
            problem = Self.describe(error)
        }
        return false
    }

    func disconnect() {
        try? Keychain.remove(account: FigmaClient.keychainAccount)
        connection = .disconnected
        me = nil
        items = []
        known = nil
        problem = nil
    }

    // MARK: - Files

    /// Adds a pasted link; returns why not, when it can't.
    func addFile(_ text: String) async -> String? {
        guard let link = FigmaLink(text) else { return L10n.string("That isn't a Figma file link.") }
        guard !files.contains(where: { $0.key == link.key }) else { return nil }
        guard files.count < Self.maxFiles else { return L10n.format("Up to %d files.", Self.maxFiles) }
        guard let client = client() else { return L10n.string("Connect Figma first.") }
        do {
            let name = try await client.fileName(link.key) ?? link.key
            preferences.update { $0.figma.files.append(.init(key: link.key, name: name)) }
            lastChecked = .distantPast
            return nil
        } catch UsageError.unauthorized {
            return L10n.string("No access to that file, or the token lacks file_metadata:read.")
        } catch {
            return Self.describe(error)
        }
    }

    func removeFile(_ key: String) {
        preferences.update { $0.figma.files.removeAll { $0.key == key } }
        items.removeAll { $0.figma?.fileKey == key }
    }

    func setNotifyComments(_ on: Bool) { preferences.update { $0.figma.notifyComments = on } }

    func setNotifyVersions(_ on: Bool) {
        preferences.update { $0.figma.notifyVersions = on }
        if !on { items.removeAll { $0.kind == .newVersion } }
        lastChecked = .distantPast
    }

    // MARK: - Checking

    /// Called by the Inbox on each of its refreshes; does nothing more often
    /// than every 5 minutes, or while Figma has asked to slow down.
    func refreshForInbox(force: Bool = false) async {
        guard connection == .connected, let client = client(), !files.isEmpty else { return }
        let now = Date()
        guard now >= pausedUntil, force || now.timeIntervalSince(lastChecked) >= Self.minInterval else { return }
        lastChecked = now
        do {
            let user: FigmaUser
            if let me { user = me } else { user = try await client.me() }
            me = user
            let since = now.addingTimeInterval(-Self.window)
            let withVersions = settings.notifyVersions
            var found: [InboxItem] = []
            for file in files {
                found += FigmaInbox.items(comments: try await client.comments(file.key), file: file.name, fileKey: file.key, me: user, since: since)
                if withVersions {
                    found += FigmaInbox.items(versions: try await client.versions(file.key), file: file.name, fileKey: file.key, me: user, since: since)
                }
            }
            announce(found)
            items = InboxItem.merged([found])
            problem = nil
            pruneRead()
        } catch UsageError.unauthorized {
            connection = .expired
            problem = L10n.string("Figma refused the token; it may have expired.")
        } catch UsageError.rateLimited(let after) {
            pausedUntil = now.addingTimeInterval(min(max(after ?? 300, 60), 3600))
            problem = L10n.string("Figma rate limit reached; trying again later.")
        } catch {
            problem = Self.describe(error)
        }
    }

    /// The first check only learns what's there; later ones flash for news.
    private func announce(_ found: [InboxItem]) {
        defer { known = (known ?? []).union(found.map(\.id)) }
        guard let known else { return }
        for item in found where !known.contains(item.id) && !isRead(item) {
            switch item.kind {
            case .mentioned, .replied: if settings.notifyComments { onNew?(item) }
            case .newVersion: if settings.notifyVersions { onNew?(item) }
            default: break
            }
        }
    }

    // MARK: - Read state

    func isRead(_ item: InboxItem) -> Bool { settings.read.contains(item.id) }

    func markRead(_ items: [InboxItem]) {
        let ids = items.filter { $0.source == .figma }.map(\.id).filter { !settings.read.contains($0) }
        if !ids.isEmpty { preferences.update { $0.figma.read = Array(($0.figma.read + ids).suffix(500)) } }
    }

    private func pruneRead() {
        guard !items.isEmpty else { return }
        let current = Set(items.map(\.id))
        let kept = settings.read.filter(current.contains)
        if kept.count < settings.read.count { preferences.update { $0.figma.read = kept } }
    }

    // MARK: - Actions

    func reply(to item: InboxItem, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let ref = item.figma, let thread = ref.threadID, let client = client() else { return false }
        do {
            try await client.reply(in: ref.fileKey, thread: thread, text: String(trimmed.prefix(5000)))
            markRead([item])
            problem = nil
            return true
        } catch {
            problem = Self.describeWrite(error)
            return false
        }
    }

    func react(to item: InboxItem) async -> Bool {
        guard let ref = item.figma, let comment = ref.commentID, let client = client() else { return false }
        do {
            try await client.react(in: ref.fileKey, comment: comment)
            markRead([item])
            problem = nil
            return true
        } catch {
            problem = Self.describeWrite(error)
            return false
        }
    }

    func copyLink(_ item: InboxItem) {
        guard FigmaLink.isSafeWebURL(item.url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
    }

    private static func describeWrite(_ error: Error) -> String {
        if case UsageError.unauthorized = error {
            return L10n.format("Replying needs a token with the %@ scope.", FigmaClient.writeScope)
        }
        return describe(error)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UsageError.rateLimited: L10n.string("Figma rate limit reached; trying again later.")
        case UsageError.network: L10n.string("Figma could not be reached.")
        default: L10n.string("Figma returned an error.")
        }
    }

    #if DEBUG
    func injectForPreview(_ items: [InboxItem], me: FigmaUser) {
        self.items = items
        self.me = me
        connection = .connected
    }
    #endif
}
