import Foundation

/// A Jira Cloud site, always `https://<name>.atlassian.net`.
///
/// Only Atlassian-hosted sites are accepted: the API token goes in every
/// request, so a typo must never send it to some other host.
struct JiraSite: Equatable, Codable, Sendable {
    let host: String

    /// "acme", "acme.atlassian.net", "https://acme.atlassian.net/jira/…" → acme.atlassian.net.
    init?(_ input: String) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if !text.contains(".") { text += ".atlassian.net" }
        guard text.hasSuffix(".atlassian.net") else { return nil }
        let name = text.dropLast(".atlassian.net".count)
        guard !name.isEmpty, !name.contains("."), name.count <= 63,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), name.first != "-" else { return nil }
        host = text
    }

    var url: URL { URL(string: "https://\(host)")! }

    func browse(_ key: String, comment: String? = nil) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/browse/\(key)"
        if let comment { components?.queryItems = [URLQueryItem(name: "focusedCommentId", value: comment)] }
        return components?.url
    }

    func search(_ jql: String) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/issues/"
        components?.queryItems = [URLQueryItem(name: "jql", value: jql)]
        return components?.url
    }

    func board(_ id: Int) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/secure/RapidBoard.jspa"
        components?.queryItems = [URLQueryItem(name: "rapidView", value: String(id))]
        return components?.url
    }

    /// Links opened in the browser must point at this site, over HTTPS.
    func owns(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == host && url.user == nil
    }
}

struct JiraAccount: Equatable, Sendable {
    let id: String
    let name: String
}

/// The four columns everything is sorted into.
enum JiraStatus: Int, CaseIterable, Sendable {
    case todo, inProgress, inReview, done

    /// From Jira's status category (`new`, `indeterminate`, `done`) and the
    /// status name — "review" in the name of an in-progress status counts as
    /// In review, which is how most workflows spell it.
    init(category: String?, name: String?) {
        switch category {
        case "done": self = .done
        case "new": self = .todo
        default:
            self = (name ?? "").lowercased().contains("review") ? .inReview : .inProgress
        }
    }

    var title: String {
        switch self {
        case .todo: L10n.string("To do")
        case .inProgress: L10n.string("In progress")
        case .inReview: L10n.string("In review")
        case .done: L10n.string("Done")
        }
    }
}

enum JiraPriority: Int, Comparable, Sendable {
    case low, medium, high

    /// Highest/High/Blocker/Critical → high; Low/Lowest/Trivial/Minor → low;
    /// anything else (Medium, custom names, none) → medium.
    init(name: String?) {
        switch (name ?? "").lowercased() {
        case "highest", "high", "blocker", "critical", "urgent", "major": self = .high
        case "low", "lowest", "trivial", "minor": self = .low
        default: self = .medium
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct JiraIssue: Identifiable, Equatable, Sendable {
    let key: String
    let summary: String
    let priority: JiraPriority
    let status: JiraStatus
    let updated: Date

    var id: String { key }

    /// Highest priority first, then most recently updated.
    static func ordered(_ issues: [JiraIssue]) -> [JiraIssue] {
        issues.sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.updated > $1.updated }
    }
}

struct JiraMention: Identifiable, Equatable, Sendable {
    let id: String
    let issueKey: String
    let issueSummary: String
    let author: String
    let authorID: String
    let body: String
    let created: Date

    var initials: String {
        let parts = author.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

struct JiraSprint: Equatable, Sendable {
    let id: Int
    let boardID: Int
    let name: String
    let start: Date?
    let end: Date?
    /// Issues in the sprint per column.
    let counts: [JiraStatus: Int]
    /// The user's issue keys per column.
    let mine: [JiraStatus: [String]]

    var total: Int { counts.values.reduce(0, +) }

    func daysLeft(now: Date) -> Int? {
        end.map { max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now),
                                                          to: Calendar.current.startOfDay(for: $0)).day ?? 0) }
    }
}

/// Decoding of the Jira Cloud responses MyHub reads.
enum JiraDecoding {
    private struct MyselfDTO: Decodable { let accountId: String; let displayName: String }

    private struct SearchDTO: Decodable {
        let issues: [Issue]
        struct Issue: Decodable {
            let key: String
            let fields: Fields
        }
        struct Fields: Decodable {
            let summary: String?
            let priority: Named?
            let status: Status?
            let updated: String?
            let assignee: Person?
        }
        struct Named: Decodable { let name: String? }
        struct Status: Decodable {
            let name: String?
            let statusCategory: Category?
            struct Category: Decodable { let key: String? }
        }
        struct Person: Decodable { let accountId: String? }
    }

    private struct CommentsDTO: Decodable {
        let comments: [Comment]
        struct Comment: Decodable {
            let id: String
            let author: Author?
            let body: ADFNode?
            let created: String
            struct Author: Decodable { let accountId: String?; let displayName: String? }
        }
    }

    private struct BoardsDTO: Decodable {
        let values: [Board]
        struct Board: Decodable { let id: Int; let name: String; let type: String? }
    }

    private struct SprintsDTO: Decodable {
        let values: [Sprint]
        struct Sprint: Decodable { let id: Int; let name: String; let startDate: String?; let endDate: String? }
    }

    static func account(from data: Data) throws -> JiraAccount {
        let me = try JSONDecoder().decode(MyselfDTO.self, from: data)
        return JiraAccount(id: me.accountId, name: me.displayName)
    }

    static func issues(from data: Data) throws -> [JiraIssue] {
        try JSONDecoder().decode(SearchDTO.self, from: data).issues.filter { JiraClient.isIssueKey($0.key) }.map { issue in
            JiraIssue(
                key: issue.key,
                summary: issue.fields.summary ?? "",
                priority: JiraPriority(name: issue.fields.priority?.name),
                status: JiraStatus(category: issue.fields.status?.statusCategory?.key, name: issue.fields.status?.name),
                updated: issue.fields.updated.flatMap(JiraDate.parse) ?? .distantPast
            )
        }
    }

    /// Per column: how many issues, and which keys belong to `accountID`.
    static func sprintColumns(from data: Data, accountID: String) throws -> (counts: [JiraStatus: Int], mine: [JiraStatus: [String]]) {
        var counts: [JiraStatus: Int] = [:]
        var mine: [JiraStatus: [String]] = [:]
        for issue in try JSONDecoder().decode(SearchDTO.self, from: data).issues {
            let status = JiraStatus(category: issue.fields.status?.statusCategory?.key, name: issue.fields.status?.name)
            counts[status, default: 0] += 1
            if issue.fields.assignee?.accountId == accountID { mine[status, default: []].append(issue.key) }
        }
        return (counts, mine)
    }

    /// Comments on `issue` that mention `accountID`, written by someone else
    /// after `since`.
    static func mentions(from data: Data, issue: JiraIssue, accountID: String, since: Date) throws -> [JiraMention] {
        try JSONDecoder().decode(CommentsDTO.self, from: data).comments.compactMap { comment in
            guard let body = comment.body, body.mentions(accountID),
                  comment.author?.accountId != accountID,
                  let created = JiraDate.parse(comment.created), created >= since else { return nil }
            return JiraMention(id: comment.id, issueKey: issue.key, issueSummary: issue.summary,
                               author: comment.author?.displayName ?? L10n.string("Someone"),
                               authorID: comment.author?.accountId ?? "", body: body.plainText, created: created)
        }
    }

    static func boards(from data: Data) throws -> [(id: Int, name: String, scrum: Bool)] {
        try JSONDecoder().decode(BoardsDTO.self, from: data).values.map { ($0.id, $0.name, $0.type == "scrum") }
    }

    static func activeSprint(from data: Data) throws -> (id: Int, name: String, start: Date?, end: Date?)? {
        guard let sprint = try JSONDecoder().decode(SprintsDTO.self, from: data).values.first else { return nil }
        return (sprint.id, sprint.name, sprint.startDate.flatMap(JiraDate.parse), sprint.endDate.flatMap(JiraDate.parse))
    }
}

/// Atlassian Document Format, as much of it as MyHub reads: the tree, text
/// and mention nodes.
struct ADFNode: Decodable, Sendable {
    let type: String
    let text: String?
    let attrs: Attrs?
    let content: [ADFNode]?

    struct Attrs: Decodable, Sendable {
        let id: String?
        let text: String?
    }

    func mentions(_ accountID: String) -> Bool {
        (type == "mention" && attrs?.id == accountID) || (content ?? []).contains { $0.mentions(accountID) }
    }

    /// Readable text: paragraphs joined by spaces, mentions as "@Name".
    var plainText: String {
        var parts: [String] = []
        collect(into: &parts)
        return parts.joined().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func collect(into parts: inout [String]) {
        switch type {
        case "text": parts.append(text ?? "")
        case "mention": parts.append(attrs?.text ?? "@")
        case "hardBreak": parts.append(" ")
        default:
            for child in content ?? [] { child.collect(into: &parts) }
            if ["paragraph", "heading", "listItem", "blockquote", "codeBlock"].contains(type) { parts.append(" ") }
        }
    }

    /// A plain-text reply as an ADF document.
    static func document(_ text: String) -> [String: Any] {
        let paragraphs = text.components(separatedBy: "\n\n").map { paragraph -> [String: Any] in
            ["type": "paragraph", "content": [["type": "text", "text": paragraph]]]
        }
        return ["type": "doc", "version": 1, "content": paragraphs]
    }
}

/// Jira's timestamps: `2026-10-01T10:15:30.123+0000` (no colon in the offset).
enum JiraDate {
    static func parse(_ string: String) -> Date? {
        if let date = ISODate.parse(string) { return date }
        // Insert the colon ISO 8601 wants: +0000 → +00:00.
        guard string.count > 5 else { return nil }
        let index = string.index(string.endIndex, offsetBy: -2)
        let sign = string[string.index(string.endIndex, offsetBy: -5)]
        guard sign == "+" || sign == "-" else { return nil }
        return ISODate.parse(String(string[..<index]) + ":" + string[index...])
    }
}
