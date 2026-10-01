import Foundation

/// What `git status --porcelain=v2 --branch` says about a working copy.
struct GitStatus: Equatable, Sendable {
    var branch: String?
    var commit: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changed = 0
    var untracked = 0
    var conflicted = 0

    var isClean: Bool { changed == 0 && untracked == 0 && conflicted == 0 }

    /// Parses porcelain v2 output. Unknown lines are ignored, so a newer git
    /// adding fields does no harm.
    static func parse(_ output: String) -> GitStatus {
        var status = GitStatus()
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("# ") {
                let fields = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard fields.count == 2 else { continue }
                switch fields[0] {
                case "branch.head": status.branch = fields[1] == "(detached)" ? nil : fields[1]
                case "branch.oid": status.commit = fields[1] == "(initial)" ? nil : fields[1]
                case "branch.upstream": status.upstream = fields[1]
                case "branch.ab":
                    for part in fields[1].split(separator: " ") {
                        if part.hasPrefix("+") { status.ahead = Int(part.dropFirst()) ?? 0 }
                        if part.hasPrefix("-") { status.behind = Int(part.dropFirst()) ?? 0 }
                    }
                default: break
                }
            } else if let kind = line.first {
                switch kind {
                case "1", "2": status.changed += 1
                case "u": status.conflicted += 1
                case "?": status.untracked += 1
                default: break
                }
            }
        }
        return status
    }
}

/// A repository on GitHub, read from a remote URL.
struct GitHubRepo: Hashable, Sendable {
    let owner: String
    let name: String

    var slug: String { "\(owner)/\(name)" }
    var webURL: URL? { URL(string: "https://github.com/\(owner)/\(name)") }

    /// `https://github.com/o/r(.git)`, `git@github.com:o/r(.git)` and
    /// `ssh://git@github.com/o/r(.git)`. Other hosts (and GitHub Enterprise)
    /// give nil.
    init?(remote: String) {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["https://github.com/", "http://github.com/", "git@github.com:", "ssh://git@github.com/", "git://github.com/"]
        guard let prefix = prefixes.first(where: { text.lowercased().hasPrefix($0) }) else { return nil }
        text.removeFirst(prefix.count)
        if text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        let parts = text.split(separator: "/")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) })
        else { return nil }
        owner = String(parts[0])
        name = String(parts[1])
    }
}

/// The combined state of a commit's checks or a workflow run.
enum CheckState: String, Codable, Sendable {
    case pending, success, failure, neutral

    /// GitHub's `status` + `conclusion` pair for check runs and workflow runs.
    init(status: String?, conclusion: String?) {
        guard status == "completed" else { self = .pending; return }
        switch conclusion {
        case "success": self = .success
        case "failure", "timed_out", "startup_failure", "action_required": self = .failure
        default: self = .neutral // cancelled, skipped, neutral, stale
        }
    }

    /// Several checks into one: any failure wins, then anything pending.
    static func combine(_ states: [CheckState]) -> CheckState? {
        if states.isEmpty { return nil }
        if states.contains(.failure) { return .failure }
        if states.contains(.pending) { return .pending }
        if states.contains(.success) { return .success }
        return .neutral
    }
}

struct PullRequestInfo: Equatable, Sendable {
    let number: Int
    let title: String
    let url: URL
    let draft: Bool
    var checks: CheckState?
}

struct WorkflowRun: Identifiable, Equatable, Sendable {
    let id: Int64
    let repo: GitHubRepo
    let workflow: String
    let title: String
    let branch: String
    let event: String
    let state: CheckState
    let url: URL
    let started: Date
    let updated: Date

    var isRunning: Bool { state == .pending }
}

/// Decoding of the few GitHub REST responses MyHub reads.
enum GitHubDecoding {
    private struct PullDTO: Decodable {
        let number: Int
        let title: String
        let html_url: String
        let draft: Bool?
        let head: Head
        struct Head: Decodable { let sha: String }
    }

    private struct CheckRunsDTO: Decodable {
        let check_runs: [Run]
        struct Run: Decodable { let status: String?; let conclusion: String? }
    }

    private struct RunsDTO: Decodable {
        let workflow_runs: [Run]
        struct Run: Decodable {
            let id: Int64
            let name: String?
            let display_title: String?
            let head_branch: String?
            let event: String?
            let status: String?
            let conclusion: String?
            let html_url: String
            let run_started_at: String?
            let created_at: String
            let updated_at: String
        }
    }

    /// The first open pull request, with its head commit for the checks call.
    static func pull(from data: Data) throws -> (PullRequestInfo, sha: String)? {
        let pulls = try JSONDecoder().decode([PullDTO].self, from: data)
        guard let pull = pulls.first, let url = safeWebURL(pull.html_url) else { return nil }
        return (PullRequestInfo(number: pull.number, title: pull.title, url: url, draft: pull.draft ?? false), pull.head.sha)
    }

    static func checks(from data: Data) throws -> CheckState? {
        let runs = try JSONDecoder().decode(CheckRunsDTO.self, from: data).check_runs
        return CheckState.combine(runs.map { CheckState(status: $0.status, conclusion: $0.conclusion) })
    }

    static func runs(from data: Data, repo: GitHubRepo) throws -> [WorkflowRun] {
        try JSONDecoder().decode(RunsDTO.self, from: data).workflow_runs.compactMap { run in
            guard let url = safeWebURL(run.html_url),
                  let created = ISODate.parse(run.run_started_at ?? run.created_at),
                  let updated = ISODate.parse(run.updated_at) else { return nil }
            return WorkflowRun(
                id: run.id, repo: repo, workflow: run.name ?? "Workflow",
                title: run.display_title ?? "", branch: run.head_branch ?? "",
                event: run.event ?? "", state: CheckState(status: run.status, conclusion: run.conclusion),
                url: url, started: created, updated: updated
            )
        }
    }

    /// Links from API responses are opened in the browser, so only
    /// `https://github.com/…` is accepted.
    static func safeWebURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil else { return nil }
        return url
    }
}
