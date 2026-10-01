import Foundation

struct CodexAuth: Sendable {
    let token: Redacted<String>
    let accountID: String?
}

enum CodexHome {
    static var url: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
}

/// ChatGPT plan limits for Codex (the 5-hour and weekly windows), from the
/// endpoint the Codex CLI uses. Undocumented: marked unofficial.
///
/// The token is read from `~/.codex/auth.json` on each fetch, read-only —
/// never stored, never refreshed by us.
struct CodexPlanProvider: UsageProvider {
    let accountID: String
    var minimumInterval: TimeInterval { 300 }
    var credentials: @Sendable () throws -> CodexAuth = { try Self.readCodexAuth(home: CodexHome.url) }

    static let host = "chatgpt.com"
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch(now: Date) async throws -> UsageSnapshot {
        let auth = try credentials()
        var headers = [
            "Authorization": "Bearer \(auth.token.exposed)",
            "Accept": "application/json",
            "User-Agent": "codex-cli",
        ]
        if let account = auth.accountID { headers["ChatGPT-Account-Id"] = account }
        let data = try await HTTPClient(allowedHosts: [Self.host]).get(Self.endpoint, headers: headers)
        return try Self.parse(data, now: now, accountID: accountID)
    }

    static func readCodexAuth(home: URL) throws -> CodexAuth {
        let file = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: file) else {
            throw UsageError.notConfigured(L10n.string("Codex is not signed in on this Mac (~/.codex/auth.json not found)."))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.notConfigured(L10n.string("~/.codex/auth.json is in a format MyHub does not recognise."))
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw UsageError.notConfigured(L10n.string("Codex is signed in with an API key, not a ChatGPT plan."))
        }
        return CodexAuth(token: Redacted(access), accountID: tokens["account_id"] as? String)
    }

    static func parse(_ data: Data, now: Date, accountID: String) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse("not a JSON object")
        }
        let limits = root["rate_limit"] as? [String: Any] ?? [:]
        let windows: [QuotaWindow] = [("primary_window", "primary"), ("secondary_window", "secondary")].compactMap { key, id in
            guard let window = limits[key] as? [String: Any],
                  let percent = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let seconds = (window["limit_window_seconds"] as? NSNumber)?.doubleValue
            var reset = (window["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if reset == nil, let after = (window["reset_after_seconds"] as? NSNumber)?.doubleValue {
                reset = now.addingTimeInterval(after)
            }
            return QuotaWindow(id: id, label: CodexWindows.label(seconds: seconds, fallback: id), used: max(0, percent / 100), resetsAt: reset)
        }
        guard !windows.isEmpty else { throw UsageError.badResponse("no rate-limit windows") }
        return UsageSnapshot(
            accountID: accountID, kind: .codexPlan,
            planLabel: (root["plan_type"] as? String).map { L10n.format("ChatGPT %@", $0.capitalized) },
            windows: windows, fidelity: .unofficial, fetchedAt: now
        )
    }
}

enum CodexWindows {
    static func label(seconds: Double?, fallback: String) -> String {
        guard let seconds, seconds > 0 else {
            return fallback == "primary" ? L10n.string("Short window") : L10n.string("Long window")
        }
        let hours = seconds / 3600
        if hours <= 24 { return L10n.format("%d-hour window", Int(hours.rounded())) }
        let days = Int((hours / 24).rounded())
        return days == 7 ? L10n.string("Weekly") : L10n.format("%d-day window", days)
    }
}

// MARK: - Local logs

struct CodexUsageRecord: Sendable, Equatable {
    struct Limit: Sendable, Equatable {
        let used: Double
        let windowMinutes: Double?
        let resetsAt: Date?
    }
    let timestamp: Date
    let model: String
    let input: Int
    let cachedInput: Int
    let output: Int
    let primary: Limit?
    let secondary: Limit?
}

/// Token usage and the last-seen plan limits from Codex's own session logs
/// (`~/.codex/sessions/**/*.jsonl`). Local only.
///
/// `token_count` events carry the per-turn usage and a snapshot of the rate
/// limits; the model comes from the session's earlier `turn_context` line.
struct CodexLogsProvider: UsageProvider {
    let accountID: String
    let ledger: LogLedger<CodexUsageRecord>
    var root: URL = CodexHome.url.appendingPathComponent("sessions")
    var minimumInterval: TimeInterval { 15 }

    static func makeLedger() -> LogLedger<CodexUsageRecord> {
        LogLedger(parse: parseLine, merge: { _, newer in newer }, timestamp: \.timestamp)
    }

    func fetch(now: Date) async throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw UsageError.notConfigured(L10n.string("No Codex sessions found in ~/.codex."))
        }
        let records = await ledger.scan(roots: [root], since: now.addingTimeInterval(-7 * 24 * 3600))
        let today = Calendar.current.startOfDay(for: now)
        var snapshot = UsageSnapshot(
            accountID: accountID, kind: .codexLogs,
            tallies: [
                Self.tally(L10n.string("Today"), records.filter { $0.timestamp >= today }),
                Self.tally(L10n.string("Last 7 days"), records),
            ],
            daily: DailySeries.build(records.map { ($0.timestamp, $0.input + $0.cachedInput + $0.output) }, now: now),
            fidelity: .estimated, fetchedAt: now
        )
        if let latest = records.filter({ $0.primary != nil || $0.secondary != nil }).max(by: { $0.timestamp < $1.timestamp }) {
            snapshot.windows = [("primary", latest.primary), ("secondary", latest.secondary)].compactMap { id, limit in
                limit.map {
                    QuotaWindow(id: id, label: CodexWindows.label(seconds: $0.windowMinutes.map { $0 * 60 }, fallback: id),
                                used: $0.used, resetsAt: $0.resetsAt)
                }
            }
            snapshot.note = L10n.format("Limits as last seen %@", latest.timestamp.formatted(.relative(presentation: .named)))
        }
        return snapshot
    }

    @Sendable static func parseLine(_ data: Data, _ context: inout [String: String], _ file: String) -> (key: String, record: CodexUsageRecord)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let type = object["type"] as? String
        let payload = object["payload"] as? [String: Any] ?? [:]
        if type == "turn_context", let model = payload["model"] as? String {
            context["model"] = model
            return nil
        }
        guard type == "event_msg", payload["type"] as? String == "token_count",
              let stamp = (object["timestamp"] as? String).flatMap(ISODate.parse) else { return nil }
        let info = payload["info"] as? [String: Any]
        let last = info?["last_token_usage"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int { (last[key] as? NSNumber)?.intValue ?? 0 }
        let cached = int("cached_input_tokens")
        let limits = payload["rate_limits"] as? [String: Any]
        let record = CodexUsageRecord(
            timestamp: stamp,
            model: context["model"] ?? "codex",
            input: max(0, int("input_tokens") - cached),
            cachedInput: cached,
            output: int("output_tokens") + int("reasoning_output_tokens"),
            primary: limit(limits?["primary"], at: stamp),
            secondary: limit(limits?["secondary"], at: stamp)
        )
        let total = (info?["total_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber
        return ("\(file)#\(object["timestamp"] as? String ?? "")#\(total?.intValue ?? 0)", record)
    }

    private static func limit(_ value: Any?, at stamp: Date) -> CodexUsageRecord.Limit? {
        guard let object = value as? [String: Any],
              let percent = (object["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        var reset = (object["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        if reset == nil, let seconds = (object["resets_in_seconds"] as? NSNumber)?.doubleValue {
            reset = stamp.addingTimeInterval(seconds)
        }
        return .init(used: percent / 100, windowMinutes: (object["window_minutes"] as? NSNumber)?.doubleValue, resetsAt: reset)
    }

    /// No price table for OpenAI models: tokens only.
    static func tally(_ label: String, _ records: [CodexUsageRecord]) -> TokenTally {
        var byModel: [String: ModelUsage] = [:]
        for r in records {
            var usage = byModel[r.model] ?? ModelUsage(model: r.model)
            usage.input += r.input
            usage.cacheRead += r.cachedInput
            usage.output += r.output
            byModel[r.model] = usage
        }
        return TokenTally(label: label, models: byModel.values.sorted { $0.totalTokens > $1.totalTokens })
    }
}
