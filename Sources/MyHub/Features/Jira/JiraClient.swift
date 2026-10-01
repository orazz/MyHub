import Foundation

/// Jira Cloud REST calls, signed with the user's email and API token (Basic
/// auth — Atlassian's documented scheme for personal scripts and tools).
///
/// Bound to the one `*.atlassian.net` host the user connected; `HTTPClient`
/// refuses anything else and never follows redirects, so the token can't be
/// carried to another host.
struct JiraClient: Sendable {
    static let keychainAccount = "jira"

    let site: JiraSite
    let email: String
    let token: Redacted<String>
    private var http: HTTPClient { HTTPClient(allowedHosts: [site.host]) }

    static let assignedJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY priority DESC, updated DESC"
    /// Tickets whose comments may tag the user in the last week.
    static let mentionScopeJQL = "(watcher = currentUser() OR assignee = currentUser() OR reporter = currentUser()) AND updated >= -7d ORDER BY updated DESC"

    private var headers: [String: String] {
        let credentials = Data("\(email):\(token.exposed)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(credentials)", "Accept": "application/json"]
    }

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL? {
        var components = URLComponents(url: site.url, resolvingAgainstBaseURL: false)
        components?.path = path
        if !query.isEmpty { components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components?.url
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        guard let url = url(path, query) else { throw UsageError.refused(L10n.string("Invalid URL.")) }
        return try await http.get(url, headers: headers)
    }

    func myself() async throws -> JiraAccount {
        try JiraDecoding.account(from: try await get("/rest/api/3/myself"))
    }

    func search(_ jql: String, fields: String = "summary,priority,status,updated", limit: Int = 50) async throws -> [JiraIssue] {
        try JiraDecoding.issues(from: try await get("/rest/api/3/search/jql", ["jql": jql, "fields": fields, "maxResults": String(limit)]))
    }

    func assigned() async throws -> [JiraIssue] {
        JiraIssue.ordered(try await search(Self.assignedJQL))
    }

    /// Comments from the last 7 days that tag the user, on up to 15 recently
    /// updated tickets they watch, own or reported. Newest first.
    func mentions(of account: JiraAccount, now: Date = Date()) async throws -> [JiraMention] {
        let since = now.addingTimeInterval(-7 * 86400)
        let issues = try await search(Self.mentionScopeJQL, fields: "summary,updated", limit: 15)
        var found: [JiraMention] = []
        for issue in issues {
            let data = try await get("/rest/api/3/issue/\(issue.key)/comment", ["orderBy": "-created", "maxResults": "20"])
            found += try JiraDecoding.mentions(from: data, issue: issue, accountID: account.id, since: since)
        }
        return found.sorted { $0.created > $1.created }
    }

    func boards() async throws -> [(id: Int, name: String, scrum: Bool)] {
        try JiraDecoding.boards(from: try await get("/rest/agile/1.0/board", ["maxResults": "50"]))
    }

    /// The active sprint on `boardID`, or — with no board chosen — on the
    /// first Scrum board whose active sprint holds one of the user's tickets.
    func activeSprint(boardID: Int?, account: JiraAccount) async throws -> JiraSprint? {
        let candidates: [Int]
        if let boardID {
            candidates = [boardID]
        } else {
            candidates = try await boards().filter(\.scrum).prefix(6).map(\.id)
        }
        var fallback: JiraSprint?
        for board in candidates {
            guard let sprint = try await JiraDecoding.activeSprint(from: get("/rest/agile/1.0/board/\(board)/sprint", ["state": "active"])) else { continue }
            let issues = try await get("/rest/agile/1.0/sprint/\(sprint.id)/issue", ["fields": "status,assignee", "maxResults": "200"])
            let columns = try JiraDecoding.sprintColumns(from: issues, accountID: account.id)
            let result = JiraSprint(id: sprint.id, boardID: board, name: sprint.name, start: sprint.start, end: sprint.end,
                                    counts: columns.counts, mine: columns.mine)
            if boardID != nil || !columns.mine.isEmpty { return result }
            fallback = fallback ?? result
        }
        return fallback
    }

    /// Posts a plain-text comment on `issueKey`.
    func reply(to issueKey: String, text: String) async throws {
        guard let url = url("/rest/api/3/issue/\(issueKey)/comment") else { return }
        let body = try JSONSerialization.data(withJSONObject: ["body": ADFNode.document(text)])
        var headers = self.headers
        headers["Content-Type"] = "application/json"
        _ = try await http.postJSON(url, body: body, headers: headers)
    }

    /// Issue keys are `PROJECT-123`; anything else never reaches a URL path.
    static func isIssueKey(_ key: String) -> Bool {
        key.range(of: "^[A-Z][A-Z0-9_]{0,19}-[0-9]{1,9}$", options: .regularExpression) != nil
    }
}
