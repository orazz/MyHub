import Foundation

/// A Figma file link the user pasted: `figma.com/design/<key>/<name>?node-id=1-2`.
/// The key is what the API takes; a branch link points at its branch key.
struct FigmaLink: Equatable, Sendable {
    let key: String
    /// "1:2" (the API form); the URL writes it "1-2".
    let nodeID: String?

    static let kinds: Set<String> = ["design", "file", "board", "proto", "slides", "site", "make"]

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host == "figma.com" || host == "www.figma.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, Self.kinds.contains(parts[0]) else { return nil }
        var key = parts[1]
        if let branch = parts.firstIndex(of: "branch"), branch + 1 < parts.count { key = parts[branch + 1] }
        guard Self.isKey(key) else { return nil }
        self.key = key
        let node = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "node-id" }?.value
        nodeID = node.flatMap { Self.isNodeID($0.replacingOccurrences(of: "-", with: ":")) ? $0.replacingOccurrences(of: "-", with: ":") : nil }
    }

    init(key: String, nodeID: String? = nil) {
        self.key = key
        self.nodeID = nodeID
    }

    /// File keys are letters and digits; nothing else reaches a URL path.
    static func isKey(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z0-9]{10,64}$", options: .regularExpression) != nil
    }

    static func isNodeID(_ id: String) -> Bool {
        id.range(of: "^[0-9]{1,12}:[0-9]{1,12}$", options: .regularExpression) != nil
    }

    static func isCommentID(_ id: String) -> Bool {
        id.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil
    }

    /// The file in the browser or the Figma app, at `node` and, for a
    /// comment, with its thread open.
    static func web(key: String, node: String? = nil, comment: String? = nil, version: String? = nil) -> URL? {
        guard isKey(key) else { return nil }
        var components = URLComponents(string: "https://www.figma.com/design/\(key)")
        var query: [URLQueryItem] = []
        if let node, isNodeID(node) { query.append(URLQueryItem(name: "node-id", value: node.replacingOccurrences(of: ":", with: "-"))) }
        if let version, isCommentID(version) { query.append(URLQueryItem(name: "version-id", value: version)) }
        components?.queryItems = query.isEmpty ? nil : query
        if let comment, isCommentID(comment) { components?.fragment = comment }
        return components?.url
    }

    /// Only Figma's own web host is ever opened from an inbox item.
    static func isSafeWebURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "www.figma.com" && url.user == nil
    }
}

struct FigmaUser: Equatable, Sendable {
    let id: String
    let handle: String
}

struct FigmaComment: Equatable, Sendable {
    let id: String
    let fileKey: String
    /// The thread it replies to; nil for a thread's first comment.
    let parentID: String?
    let user: FigmaUser
    let created: Date
    let resolved: Bool
    let message: String
    /// The frame it's pinned to, when it is.
    let nodeID: String?

    var rootID: String { parentID ?? id }
}

struct FigmaVersion: Equatable, Sendable {
    let id: String
    let created: Date
    /// Set for named versions; autosaves have none.
    let label: String?
    let description: String?
    let user: FigmaUser
}

/// What a Figma inbox row needs to act on its comment: reply, react, link.
struct FigmaRef: Equatable, Sendable {
    let fileKey: String
    /// The thread to reply to (a root comment); nil for a version.
    let threadID: String?
    /// The comment itself, for reactions.
    let commentID: String?
    let nodeID: String?
}

enum FigmaDecoding {
    private struct UserDTO: Decodable {
        let id: String?
        let handle: String?
        var user: FigmaUser { FigmaUser(id: id ?? "", handle: AgentEvent.clip(handle ?? "", 80)) }
    }

    private struct CommentsDTO: Decodable {
        let comments: [Comment]
        struct Comment: Decodable {
            let id: String
            let file_key: String?
            let parent_id: String?
            let user: UserDTO?
            let created_at: String
            let resolved_at: String?
            let message: String?
            let client_meta: Meta?
        }
        /// Only the frame matters here; the pin's offsets are ignored.
        struct Meta: Decodable { let node_id: String? }
    }

    private struct VersionsDTO: Decodable {
        let versions: [Version]
        struct Version: Decodable {
            let id: String
            let created_at: String
            let label: String?
            let description: String?
            let user: UserDTO?
        }
    }

    private struct MetaDTO: Decodable {
        let file: File
        struct File: Decodable { let name: String? }
    }

    static func me(from data: Data) throws -> FigmaUser {
        try JSONDecoder().decode(UserDTO.self, from: data).user
    }

    static func fileName(from data: Data) throws -> String? {
        try JSONDecoder().decode(MetaDTO.self, from: data).file.name.map { AgentEvent.clip($0, 120) }
    }

    static func comments(from data: Data, fileKey: String) throws -> [FigmaComment] {
        try JSONDecoder().decode(CommentsDTO.self, from: data).comments.compactMap { comment in
            guard FigmaLink.isCommentID(comment.id), let created = ISODate.parse(comment.created_at) else { return nil }
            let node = comment.client_meta?.node_id.flatMap { FigmaLink.isNodeID($0) ? $0 : nil }
            return FigmaComment(id: comment.id, fileKey: fileKey, parentID: comment.parent_id.flatMap { $0.isEmpty ? nil : $0 },
                                user: comment.user?.user ?? FigmaUser(id: "", handle: ""), created: created,
                                resolved: comment.resolved_at != nil, message: GitHubInboxDecoding.snippet(comment.message), nodeID: node)
        }
    }

    static func versions(from data: Data) throws -> [FigmaVersion] {
        try JSONDecoder().decode(VersionsDTO.self, from: data).versions.compactMap { version in
            guard let created = ISODate.parse(version.created_at) else { return nil }
            let label = version.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            return FigmaVersion(id: version.id, created: created, label: label?.isEmpty == false ? AgentEvent.clip(label!, 120) : nil,
                                description: version.description.map { GitHubInboxDecoding.snippet($0) },
                                user: version.user?.user ?? FigmaUser(id: "", handle: ""))
        }
    }
}

/// Turns a watched file's comments and versions into inbox items.
enum FigmaInbox {
    /// Comments from the last 7 days by someone else, unresolved:
    /// - one that @mentions the user → Mentions;
    /// - a reply in a thread the user started or joined → a reply;
    /// - anything else on the file → a comment.
    static func items(comments: [FigmaComment], file: String, fileKey: String, me: FigmaUser, since: Date) -> [InboxItem] {
        let threads = Dictionary(grouping: comments, by: \.rootID)
        let resolvedThreads = Set(comments.filter { $0.parentID == nil && $0.resolved }.map(\.id))
        return comments.compactMap { comment in
            guard comment.user.id != me.id, comment.created >= since, !resolvedThreads.contains(comment.rootID) else { return nil }
            let joined = threads[comment.rootID, default: []].contains { $0.user.id == me.id }
            let kind: InboxItem.Kind = mentions(comment.message, me) ? .mentioned : (comment.parentID != nil && joined ? .replied : .commented)
            guard let url = FigmaLink.web(key: fileKey, node: comment.nodeID, comment: comment.rootID) else { return nil }
            return InboxItem(id: "figma-c-\(comment.id)", source: .figma, kind: kind, title: file, reference: "Figma",
                             actor: comment.user.handle, snippet: comment.message, date: comment.created, url: url,
                             figma: FigmaRef(fileKey: fileKey, threadID: comment.rootID, commentID: comment.id, nodeID: comment.nodeID))
        }
    }

    /// Named versions from the last 7 days, saved by someone else.
    static func items(versions: [FigmaVersion], file: String, fileKey: String, me: FigmaUser, since: Date) -> [InboxItem] {
        versions.compactMap { version in
            guard let label = version.label, version.user.id != me.id, version.created >= since,
                  let url = FigmaLink.web(key: fileKey, version: version.id) else { return nil }
            return InboxItem(id: "figma-v-\(fileKey)-\(version.id)", source: .figma, kind: .newVersion, title: label, reference: file,
                             actor: version.user.handle, snippet: version.description ?? "", date: version.created, url: url,
                             figma: FigmaRef(fileKey: fileKey, threadID: nil, commentID: nil, nodeID: nil))
        }
    }

    /// "@Ana Lee" for the user's handle, as Figma writes mentions in text.
    static func mentions(_ message: String, _ me: FigmaUser) -> Bool {
        guard !me.handle.isEmpty else { return false }
        return message.range(of: "@" + me.handle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
