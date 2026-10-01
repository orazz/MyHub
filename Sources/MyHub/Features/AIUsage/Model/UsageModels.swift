import Foundation

/// Every usage source MyHub knows how to read.
enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claudePlan, claudeLogs, codexPlan, codexLogs
    case anthropicAdmin, openAIAdmin, openRouter, bedrock, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudePlan: L10n.string("Claude plan")
        case .claudeLogs: L10n.string("Claude Code on this Mac")
        case .codexPlan: L10n.string("ChatGPT / Codex plan")
        case .codexLogs: L10n.string("Codex on this Mac")
        case .anthropicAdmin: L10n.string("Anthropic API")
        case .openAIAdmin: L10n.string("OpenAI API")
        case .openRouter: L10n.string("OpenRouter")
        case .bedrock: L10n.string("AWS Bedrock")
        case .custom: L10n.string("Custom endpoint")
        }
    }

    var symbol: String {
        switch self {
        case .claudePlan, .anthropicAdmin: "sparkle"
        case .claudeLogs, .codexLogs: "terminal"
        case .codexPlan, .openAIAdmin: "circle.hexagongrid"
        case .openRouter: "arrow.triangle.branch"
        case .bedrock: "cloud"
        case .custom: "link"
        }
    }

    /// What adding this source reads, and what the user will be asked.
    var explanation: String {
        switch self {
        case .claudePlan:
            L10n.string("Reads Claude Code's sign-in from the Keychain (macOS will ask once) to show your 5-hour and weekly limits. Unofficial endpoint.")
        case .claudeLogs:
            L10n.string("Reads Claude Code's local logs in ~/.claude. Nothing leaves this Mac. Cost is an API-price estimate.")
        case .codexPlan:
            L10n.string("Reads Codex's sign-in from ~/.codex/auth.json to show your ChatGPT plan limits. Unofficial endpoint.")
        case .codexLogs:
            L10n.string("Reads Codex's local session logs in ~/.codex. Nothing leaves this Mac.")
        case .anthropicAdmin:
            L10n.string("Organisation spend this month and tokens by model, from the official Usage & Cost API. Needs an Admin key (sk-ant-admin…), kept in the Keychain.")
        case .openAIAdmin:
            L10n.string("Organisation spend this month and tokens by model, from the official Usage and Costs API. Needs an Admin key (sk-admin-…), kept in the Keychain.")
        case .openRouter:
            L10n.string("Credits used today, this week and this month, and the key's limit. Needs an OpenRouter API key, kept in the Keychain.")
        case .bedrock:
            L10n.string("Tokens by model from CloudWatch, optional monthly cost from Cost Explorer. Uses access keys (Keychain) or an AWS profile.")
        case .custom:
            L10n.string("Any endpoint that returns JSON — a LiteLLM proxy or your own gateway. You map which fields mean used, limit and spend.")
        }
    }

    /// Needs a form (key, URL, region…) before it can be added.
    var needsSetup: Bool {
        switch self {
        case .claudePlan, .claudeLogs, .codexPlan, .codexLogs: false
        case .anthropicAdmin, .openAIAdmin, .openRouter, .bedrock, .custom: true
        }
    }

    /// Local sources describe this Mac, so one of each is enough; API sources
    /// can be added once per key (several orgs, several proxies).
    var allowsMultiple: Bool {
        switch self {
        case .claudePlan, .claudeLogs, .codexPlan, .codexLogs: false
        case .anthropicAdmin, .openAIAdmin, .openRouter, .bedrock, .custom: true
        }
    }

    /// Sources implemented so far; the rest arrive with API keys in Phase 7.
    var isAvailable: Bool { true }
}

enum Fidelity: String, Sendable, Equatable {
    /// A documented API.
    case official
    /// An endpoint that works but is not documented — may change without notice.
    case unofficial
    /// Computed on this Mac from local logs and a price table.
    case estimated

    var label: String {
        switch self {
        case .official: L10n.string("Official")
        case .unofficial: L10n.string("Unofficial")
        case .estimated: L10n.string("Estimated")
        }
    }
}

/// One configured source. Secrets are never stored here — only in the
/// Keychain, under `id`.
struct UsageAccount: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: ProviderKind
    var label: String
    var enabled: Bool = true
    var options: [String: String] = [:]
}

struct QuotaWindow: Sendable, Equatable, Identifiable {
    let id: String
    let label: String
    /// 0 = untouched, 1 = limit reached. May exceed 1 on some plans.
    let used: Double
    let resetsAt: Date?
}

struct Money: Sendable, Equatable {
    let amount: Decimal
    let currency: String

    var formatted: String {
        amount.formatted(.currency(code: currency).precision(.fractionLength(2)))
    }
}

struct SpendLine: Sendable, Equatable, Identifiable {
    var id: String { label }
    let label: String
    let money: Money
    let limit: Money?
}

struct ModelUsage: Sendable, Equatable, Identifiable {
    var id: String { model }
    let model: String
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// nil when the model is not in the price table.
    var cost: Decimal?

    var totalTokens: Int { input + output + cacheRead + cacheWrite }
}

struct TokenTally: Sendable, Equatable, Identifiable {
    var id: String { label }
    let label: String
    let models: [ModelUsage]

    var totalTokens: Int { models.reduce(0) { $0 + $1.totalTokens } }
    /// Sum over models with a known price.
    var cost: Decimal? {
        let known = models.compactMap(\.cost)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
    var costIsPartial: Bool { models.contains { $0.cost == nil && $0.totalTokens > 0 } }
}

/// Tokens on one day, for the 7-day chart.
struct DayTokens: Sendable, Equatable, Identifiable {
    var id: Date { day }
    let day: Date
    let tokens: Int
}

enum DailySeries {
    /// Seven days ending today (oldest first), each the sum of the samples
    /// that fall on it; days without samples are zero.
    static func build(_ samples: [(date: Date, tokens: Int)], now: Date, calendar: Calendar = .current) -> [DayTokens] {
        let today = calendar.startOfDay(for: now)
        let days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        var totals: [Date: Int] = [:]
        for sample in samples {
            totals[calendar.startOfDay(for: sample.date), default: 0] += sample.tokens
        }
        return days.map { DayTokens(day: $0, tokens: totals[$0] ?? 0) }
    }
}

struct Share: Sendable, Equatable, Identifiable {
    var id: String { label }
    let label: String
    let fraction: Double
}

struct UsageSnapshot: Sendable, Equatable {
    let accountID: String
    let kind: ProviderKind
    var planLabel: String?
    var windows: [QuotaWindow] = []
    var spend: [SpendLine] = []
    var tallies: [TokenTally] = []
    var shares: [Share] = []
    /// Seven days, oldest first, when the source knows tokens per day.
    var daily: [DayTokens] = []
    var fidelity: Fidelity
    var fetchedAt: Date
    var note: String?

    var highestWindow: QuotaWindow? { windows.max { $0.used < $1.used } }
}

enum UsageError: Error, Sendable, Equatable {
    case notConfigured(String)
    case unauthorized
    case expired(String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    /// A non-2xx answer with the server's own explanation.
    case server(Int, String)
    case badResponse(String)
    case network(String)
    case refused(String)

    var message: String {
        switch self {
        case .notConfigured(let why): why
        case .unauthorized: L10n.string("Not authorized — the sign-in or key was rejected.")
        case .expired(let hint): hint
        case .rateLimited: L10n.string("Rate limited — will retry later.")
        case .http(let code): L10n.format("Server answered %d.", code)
        case .server(let code, let message): L10n.format("Server answered %d: %@", code, message)
        case .badResponse(let why): L10n.format("Unexpected response: %@", why)
        case .network(let why): why
        case .refused(let why): why
        }
    }

    var retryAfter: TimeInterval? {
        if case .rateLimited(let after) = self { return after }
        return nil
    }
}

/// A source of usage numbers. Stateless and `Sendable`: whatever must persist
/// between fetches (backoff, log cursors) lives in an actor it is handed.
protocol UsageProvider: Sendable {
    var accountID: String { get }
    /// Fetches closer together than this are skipped (unless forced).
    var minimumInterval: TimeInterval { get }
    func fetch(now: Date) async throws -> UsageSnapshot
}
