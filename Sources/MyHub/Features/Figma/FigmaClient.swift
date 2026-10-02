import Foundation

/// Figma REST calls with the user's personal access token (`X-Figma-Token`).
///
/// Bound to `api.figma.com`; `HTTPClient` refuses any other host and never
/// follows redirects, so the token can't be carried elsewhere. Comments and
/// versions are rate-limited per seat (as few as 5 calls a minute on a View
/// seat), so the store calls this sparingly.
struct FigmaClient: Sendable {
    static let keychainAccount = "figma"
    static let host = "api.figma.com"

    /// The scopes to tick when creating the token. Write is optional: without
    /// it, reply and react are refused and everything else works.
    static let readScopes = ["current_user:read", "file_comments:read", "file_metadata:read", "file_versions:read"]
    static let writeScope = "file_comments:write"

    let token: Redacted<String>
    private var http: HTTPClient { HTTPClient(allowedHosts: [Self.host]) }

    static func storedToken() -> Redacted<String>? {
        (try? Keychain.secret(account: keychainAccount)).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var headers: [String: String] { ["X-Figma-Token": token.exposed, "Accept": "application/json"] }

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = path
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        guard let url = url(path, query) else { throw UsageError.refused(L10n.string("Invalid URL.")) }
        return try await http.get(url, headers: headers)
    }

    private func post(_ path: String, _ body: [String: Any]) async throws {
        guard let url = url(path) else { throw UsageError.refused(L10n.string("Invalid URL.")) }
        var headers = self.headers
        headers["Content-Type"] = "application/json"
        _ = try await http.postJSON(url, body: try JSONSerialization.data(withJSONObject: body), headers: headers)
    }

    func me() async throws -> FigmaUser {
        try FigmaDecoding.me(from: try await get("/v1/me"))
    }

    func fileName(_ key: String) async throws -> String? {
        guard FigmaLink.isKey(key) else { return nil }
        return try FigmaDecoding.fileName(from: try await get("/v1/files/\(key)/meta"))
    }

    func comments(_ key: String) async throws -> [FigmaComment] {
        guard FigmaLink.isKey(key) else { return [] }
        return try FigmaDecoding.comments(from: try await get("/v1/files/\(key)/comments"), fileKey: key)
    }

    /// The latest versions, newest first (named ones and autosaves).
    func versions(_ key: String) async throws -> [FigmaVersion] {
        guard FigmaLink.isKey(key) else { return [] }
        return try FigmaDecoding.versions(from: try await get("/v1/files/\(key)/versions", ["page_size": "20"]))
    }

    /// A reply in the thread `threadID` (replies go on root comments only).
    func reply(in key: String, thread threadID: String, text: String) async throws {
        guard FigmaLink.isKey(key), FigmaLink.isCommentID(threadID) else { return }
        try await post("/v1/files/\(key)/comments", ["message": text, "comment_id": threadID])
    }

    /// A reaction such as `:+1:` on a comment.
    func react(in key: String, comment commentID: String, emoji: String = ":+1:") async throws {
        guard FigmaLink.isKey(key), FigmaLink.isCommentID(commentID) else { return }
        try await post("/v1/files/\(key)/comments/\(commentID)/reactions", ["emoji": emoji])
    }
}
