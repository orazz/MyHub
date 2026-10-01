import Foundation

/// The provider segments at the top of the AI usage tab. Claude's plan, its
/// local logs and the Anthropic API are one provider to a person; so are the
/// ChatGPT plan, Codex and the OpenAI API. Everything else is its own segment.
struct UsageGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let accounts: [UsageAccount]

    static func build(_ accounts: [UsageAccount]) -> [UsageGroup] {
        let claudeKinds: Set<ProviderKind> = [.claudePlan, .claudeLogs, .anthropicAdmin]
        let openAIKinds: Set<ProviderKind> = [.codexPlan, .codexLogs, .openAIAdmin]
        var groups: [UsageGroup] = []
        let claude = accounts.filter { claudeKinds.contains($0.kind) }
        if !claude.isEmpty { groups.append(UsageGroup(id: "claude", title: "Claude", accounts: claude)) }
        let openAI = accounts.filter { openAIKinds.contains($0.kind) }
        if !openAI.isEmpty { groups.append(UsageGroup(id: "chatgpt", title: "ChatGPT", accounts: openAI)) }
        for account in accounts where !claudeKinds.contains(account.kind) && !openAIKinds.contains(account.kind) {
            groups.append(UsageGroup(id: account.id, title: account.label, accounts: [account]))
        }
        return groups
    }
}

/// What the three cards show for one group, merged from its sources.
struct UsageSummary: Equatable {
    /// First card: the short limit window, or today's spend.
    var session: Stat?
    /// Second card: the long window, or this month's spend.
    var weekly: Stat?
    var daily: [DayTokens] = []
    var plan: String?
    var fetchedAt: Date?
    var problems: [String] = []

    struct Stat: Equatable {
        let title: String
        let value: String
        /// 0…1 for a bar; nil for a plain amount.
        let progress: Double?
        let resetsAt: Date?
        let footnote: String?
    }

    var todayTokens: Int? { daily.last.map(\.tokens) }

    static func build(group: UsageGroup, snapshots: [String: UsageSnapshot], errors: [String: UsageError]) -> UsageSummary {
        var summary = UsageSummary()
        let available = group.accounts.compactMap { snapshots[$0.id] }
        let windows = available.flatMap(\.windows)

        func stat(_ window: QuotaWindow, title: String) -> Stat {
            Stat(title: title, value: "\(Int((window.used * 100).rounded()))%", progress: window.used, resetsAt: window.resetsAt, footnote: nil)
        }
        let short = windows.first { ["five_hour", "primary", "limit", "percent", "budget"].contains($0.id) }
        let long = windows.first { ["seven_day", "secondary"].contains($0.id) }
        if let short { summary.session = stat(short, title: short.id == "five_hour" || short.id == "primary" ? L10n.string("Current session") : short.label) }
        if let long { summary.weekly = stat(long, title: L10n.string("Weekly limit")) }

        let spend = available.flatMap(\.spend)
        func money(_ line: SpendLine) -> Stat {
            Stat(title: line.label, value: line.money.formatted,
                 progress: line.limit.map { NSDecimalNumber(decimal: line.money.amount / max($0.amount, 0.0001)).doubleValue },
                 resetsAt: nil, footnote: line.limit.map { L10n.format("of %@", $0.formatted) })
        }
        if summary.session == nil, let today = spend.first(where: { $0.label == L10n.string("Today") }) ?? spend.first {
            summary.session = money(today)
        }
        if summary.weekly == nil, let month = spend.first(where: { $0.label == L10n.string("This month") })
            ?? spend.first(where: { $0.label != summary.session?.title }) {
            summary.weekly = money(month)
        }

        // Local logs count exactly; the admin APIs lag a few minutes.
        let byPreference = available.sorted { rank($0.kind) < rank($1.kind) }
        summary.daily = byPreference.first { !$0.daily.isEmpty }?.daily ?? []
        summary.plan = available.compactMap(\.planLabel).first
        summary.fetchedAt = available.map(\.fetchedAt).max()
        summary.problems = group.accounts.compactMap { account in
            errors[account.id].map { "\(account.label): \($0.message)" }
        }
        return summary
    }

    private static func rank(_ kind: ProviderKind) -> Int {
        switch kind {
        case .claudeLogs, .codexLogs: 0
        case .anthropicAdmin, .openAIAdmin, .bedrock: 1
        default: 2
        }
    }
}
