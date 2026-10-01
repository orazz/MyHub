import Foundation

/// Read-only GitHub REST calls: the open pull request for a branch, its
/// checks, and recent workflow runs.
///
/// Goes through `HTTPClient`, bound to `api.github.com` only. The token is
/// optional: public repositories work without one, within GitHub's limit of
/// 60 requests an hour; a fine-grained, read-only token raises that to 5,000
/// and adds private repositories. It is kept in the Keychain and never written
/// anywhere else.
struct GitHubClient: Sendable {
    static let keychainAccount = "github"

    let token: Redacted<String>?
    private let http = HTTPClient(allowedHosts: ["api.github.com"])

    static func storedToken() -> Redacted<String>? {
        (try? Keychain.secret(account: keychainAccount)).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var headers: [String: String] {
        var headers = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        if let token { headers["Authorization"] = "Bearer \(token.exposed)" }
        return headers
    }

    private func url(_ repo: GitHubRepo, _ path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repo.owner)/\(repo.name)\(path)"
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    /// The open pull request whose head is `branch`, with its checks.
    func pullRequest(_ repo: GitHubRepo, branch: String) async throws -> PullRequestInfo? {
        guard let url = url(repo, "/pulls", query: [
            URLQueryItem(name: "head", value: "\(repo.owner):\(branch)"),
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "per_page", value: "1"),
        ]) else { return nil }
        guard let found = try GitHubDecoding.pull(from: try await http.get(url, headers: headers)) else { return nil }
        var pull = found.0
        let sha = found.sha
        if let checksURL = self.url(repo, "/commits/\(sha)/check-runs", query: [URLQueryItem(name: "per_page", value: "50")]) {
            pull.checks = try? GitHubDecoding.checks(from: try await http.get(checksURL, headers: headers))
        }
        return pull
    }

    func runs(_ repo: GitHubRepo, limit: Int = 6) async throws -> [WorkflowRun] {
        guard let url = url(repo, "/actions/runs", query: [URLQueryItem(name: "per_page", value: String(limit))]) else { return [] }
        return try GitHubDecoding.runs(from: try await http.get(url, headers: headers), repo: repo)
    }
}

// MARK: - Inbox

extension GitHubClient {
    private func api(_ path: String, _ query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    private func search(_ q: String, limit: Int) async throws -> [GitHubInboxDecoding.Hit] {
        guard let url = api("/search/issues", [URLQueryItem(name: "q", value: q), URLQueryItem(name: "per_page", value: String(limit)),
                                               URLQueryItem(name: "sort", value: "updated")]) else { return [] }
        return try GitHubInboxDecoding.hits(from: try await http.get(url, headers: headers))
    }

    /// Everything for the inbox from the last `days`: review requests, new
    /// reviews and comments on the user's open pull requests, and mentions.
    /// Needs a token — "@me" means nothing to an anonymous request.
    func inbox(days: Int = 7, now: Date = Date()) async throws -> [InboxItem] {
        guard token != nil, let userURL = api("/user") else { return [] }
        let me = try GitHubInboxDecoding.login(from: try await http.get(userURL, headers: headers))
        let since = now.addingTimeInterval(-Double(days) * 86400)
        let day = since.formatted(.iso8601.year().month().day())

        var lists: [[InboxItem]] = []
        let requested = try await search("is:pr is:open archived:false review-requested:@me", limit: 20)
        lists.append(requested.map { pull in
            InboxItem(id: "gh-request-\(pull.id)", source: .github, kind: .reviewRequested, title: pull.title,
                      reference: pull.reference, actor: pull.author, snippet: "", date: pull.updated, url: pull.url)
        })

        let mine = try await search("is:pr is:open archived:false author:@me updated:>=\(day)", limit: 10)
        let sinceText = ISO8601DateFormatter().string(from: since)
        for pull in mine {
            let base = "/repos/\(pull.repo.owner)/\(pull.repo.name)"
            if let url = api("\(base)/pulls/\(pull.number)/reviews", [URLQueryItem(name: "per_page", value: "50")]),
               let data = try? await http.get(url, headers: headers) {
                lists.append((try? GitHubInboxDecoding.reviews(from: data, on: pull, me: me, since: since)) ?? [])
            }
            for path in ["\(base)/issues/\(pull.number)/comments", "\(base)/pulls/\(pull.number)/comments"] {
                if let url = api(path, [URLQueryItem(name: "since", value: sinceText), URLQueryItem(name: "per_page", value: "50")]),
                   let data = try? await http.get(url, headers: headers) {
                    lists.append((try? GitHubInboxDecoding.comments(from: data, on: pull, me: me, since: since)) ?? [])
                }
            }
        }

        let mentions = try await search("mentions:@me updated:>=\(day)", limit: 20)
        lists.append(mentions.map { hit in
            // Search says where, not who: the author of the issue is not
            // necessarily the person who mentioned the user.
            InboxItem(id: "gh-mention-\(hit.id)", source: .github, kind: .mentioned, title: hit.title,
                      reference: hit.reference, actor: "", snippet: "", date: hit.updated, url: hit.url)
        })
        return InboxItem.merged(lists)
    }
}
