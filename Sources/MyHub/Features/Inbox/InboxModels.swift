import Foundation

/// One thing that wants the user's attention, from any source.
struct InboxItem: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable { case github, jira }

    enum Kind: Equatable, Sendable {
        case reviewRequested
        case approved
        case changesRequested
        case reviewed
        case commented
        case mentioned

        var title: String {
            switch self {
            case .reviewRequested: L10n.string("Review requested")
            case .approved: L10n.string("Approved")
            case .changesRequested: L10n.string("Changes requested")
            case .reviewed: L10n.string("Reviewed")
            case .commented: L10n.string("Commented")
            case .mentioned: L10n.string("Mentioned you")
            }
        }
    }

    /// Stable across refreshes, so read state sticks: source, kind and the
    /// id of the review, comment or request it comes from.
    let id: String
    let source: Source
    let kind: Kind
    /// The pull request, issue or ticket.
    let title: String
    /// "orazz/orbit #128" or "ORB-142".
    let reference: String
    let actor: String
    /// The comment or review text, when there is one.
    let snippet: String
    let date: Date
    let url: URL

    /// Newest first; at most one item per id.
    static func merged(_ lists: [[InboxItem]]) -> [InboxItem] {
        var seen = Set<String>()
        return lists.joined().sorted { $0.date > $1.date }.filter { seen.insert($0.id).inserted }
    }
}

/// Decoding of the GitHub responses the inbox reads.
enum GitHubInboxDecoding {
    private struct SearchDTO: Decodable {
        let items: [Item]
        struct Item: Decodable {
            let id: Int64
            let number: Int
            let title: String
            let html_url: String
            let repository_url: String
            let updated_at: String
            let user: User?
            let pull_request: PullRef?
        }
        struct PullRef: Decodable { let url: String? }
    }

    struct User: Decodable, Sendable { let login: String }

    private struct ReviewDTO: Decodable {
        let id: Int64
        let user: User?
        let state: String
        let body: String?
        let submitted_at: String?
        let html_url: String
    }

    private struct CommentDTO: Decodable {
        let id: Int64
        let user: User?
        let body: String?
        let created_at: String
        let html_url: String
    }

    /// A search hit: an open pull request or issue.
    struct Hit: Equatable, Sendable {
        let id: Int64
        let number: Int
        let title: String
        let url: URL
        let repo: GitHubRepo
        let author: String
        let updated: Date
        let isPullRequest: Bool

        var reference: String { "\(repo.slug) #\(number)" }
    }

    static func login(from data: Data) throws -> String {
        try JSONDecoder().decode(User.self, from: data).login
    }

    static func hits(from data: Data) throws -> [Hit] {
        try JSONDecoder().decode(SearchDTO.self, from: data).items.compactMap { item in
            guard let url = GitHubDecoding.safeWebURL(item.html_url),
                  let repo = repo(fromAPI: item.repository_url),
                  let updated = ISODate.parse(item.updated_at) else { return nil }
            return Hit(id: item.id, number: item.number, title: item.title, url: url, repo: repo,
                       author: item.user?.login ?? "", updated: updated, isPullRequest: item.pull_request != nil)
        }
    }

    /// `https://api.github.com/repos/owner/name` → owner/name.
    static func repo(fromAPI string: String) -> GitHubRepo? {
        let prefix = "https://api.github.com/repos/"
        guard string.hasPrefix(prefix) else { return nil }
        return GitHubRepo(remote: "https://github.com/" + string.dropFirst(prefix.count))
    }

    /// Reviews on `pull` by someone other than `me`, submitted after `since`.
    static func reviews(from data: Data, on pull: Hit, me: String, since: Date) throws -> [InboxItem] {
        try JSONDecoder().decode([ReviewDTO].self, from: data).compactMap { review in
            guard let author = review.user?.login, author.caseInsensitiveCompare(me) != .orderedSame,
                  let date = review.submitted_at.flatMap(ISODate.parse), date >= since,
                  let url = GitHubDecoding.safeWebURL(review.html_url) else { return nil }
            let kind: InboxItem.Kind
            switch review.state {
            case "APPROVED": kind = .approved
            case "CHANGES_REQUESTED": kind = .changesRequested
            case "COMMENTED": kind = .reviewed
            default: return nil  // PENDING, DISMISSED
            }
            return InboxItem(id: "gh-review-\(review.id)", source: .github, kind: kind, title: pull.title,
                             reference: pull.reference, actor: author, snippet: snippet(review.body), date: date, url: url)
        }
    }

    /// Conversation or inline comments on `pull` by someone other than `me`.
    static func comments(from data: Data, on pull: Hit, me: String, since: Date) throws -> [InboxItem] {
        try JSONDecoder().decode([CommentDTO].self, from: data).compactMap { comment in
            guard let author = comment.user?.login, author.caseInsensitiveCompare(me) != .orderedSame,
                  !author.hasSuffix("[bot]"),
                  let date = ISODate.parse(comment.created_at), date >= since,
                  let url = GitHubDecoding.safeWebURL(comment.html_url) else { return nil }
            return InboxItem(id: "gh-comment-\(comment.id)", source: .github, kind: .commented, title: pull.title,
                             reference: pull.reference, actor: author, snippet: snippet(comment.body), date: date, url: url)
        }
    }

    /// One line of readable text from Markdown: no quotes, no code fences,
    /// whitespace collapsed, cut at 200 characters.
    static func snippet(_ body: String?) -> String {
        guard let body else { return "" }
        let lines = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix(">") && !$0.hasPrefix("```") && !$0.hasPrefix("<!--") }
        let text = lines.joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(text.prefix(200))
    }
}

extension InboxItem {
    /// The three sections of the inbox, in the order they are shown.
    enum Group: Int, CaseIterable, Sendable {
        case needsReview, reviewsOnYours, mentions

        var title: String {
            switch self {
            case .needsReview: L10n.string("Needs your review")
            case .reviewsOnYours: L10n.string("Reviews on your pull requests")
            case .mentions: L10n.string("Mentions")
            }
        }
    }

    var group: Group {
        switch kind {
        case .reviewRequested: .needsReview
        case .approved, .changesRequested, .reviewed, .commented: .reviewsOnYours
        case .mentioned: .mentions
        }
    }

    /// "orazz/orbit #128" → "orbit #128"; Jira keys unchanged.
    var shortReference: String {
        guard source == .github, let slash = reference.firstIndex(of: "/") else { return reference }
        return String(reference[reference.index(after: slash)...])
    }
}

/// A title split into a leading tag and the rest: a conventional-commit
/// prefix ("feat(api): Make …" → feat · api) or a ticket key
/// ("[ORB-412] Upgrade sheet" → ORB-412).
struct TaggedTitle: Equatable, Sendable {
    enum Tag: Equatable, Sendable {
        case change(type: String, scope: String?)
        case ticket(String)
    }

    let tag: Tag?
    let text: String

    /// Commit types worth a chip; anything else stays part of the title.
    static let changeTypes: Set<String> = ["feat", "fix", "chore", "refactor", "docs", "test", "perf", "build", "ci", "style", "revert"]

    init(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let match = try? NSRegularExpression(pattern: #"^([a-zA-Z]+)(?:\(([^)]{1,40})\))?!?:\s*(.+)$"#).firstMatch(in: trimmed, range: full),
           Self.changeTypes.contains(ns.substring(with: match.range(at: 1)).lowercased()) {
            let scope = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            tag = .change(type: ns.substring(with: match.range(at: 1)).lowercased(), scope: scope)
            text = ns.substring(with: match.range(at: 3))
        } else if let match = try? NSRegularExpression(pattern: #"^\[?([A-Z][A-Z0-9]{1,9}-[0-9]{1,7})\]?[\s:–-]+(.+)$"#).firstMatch(in: trimmed, range: full) {
            tag = .ticket(ns.substring(with: match.range(at: 1)))
            text = ns.substring(with: match.range(at: 2))
        } else {
            tag = nil
            text = trimmed
        }
    }
}
