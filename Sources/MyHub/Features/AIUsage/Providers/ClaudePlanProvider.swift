import Foundation

struct ClaudeOAuth: Sendable {
    let token: Redacted<String>
    let expiresAt: Date?
    let plan: String?
}

/// Claude Pro / Max limits — the 5-hour session and the weekly windows — from
/// the endpoint Claude Code itself uses. Undocumented: marked unofficial, and
/// polled no more than every five minutes.
///
/// The OAuth token is Claude Code's, read from its Keychain item on each
/// fetch. It is never copied, stored, refreshed or written back: refreshing it
/// ourselves would race Claude Code's own refresh and could sign it out.
struct ClaudePlanProvider: UsageProvider {
    let accountID: String
    var minimumInterval: TimeInterval { 300 }
    var credentials: @Sendable () throws -> ClaudeOAuth = { try Self.readClaudeCodeCredentials() }

    static let host = "api.anthropic.com"
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    private var http: HTTPClient { HTTPClient(allowedHosts: [Self.host]) }

    func fetch(now: Date) async throws -> UsageSnapshot {
        let credential = try credentials()
        if let expiry = credential.expiresAt, expiry <= now {
            throw UsageError.expired(L10n.string("Claude Code's sign-in has expired — open Claude Code once to refresh it."))
        }
        let data = try await http.get(Self.endpoint, headers: [
            "Authorization": "Bearer \(credential.token.exposed)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
        ])
        var snapshot = try Self.parse(data, now: now, accountID: accountID)
        snapshot.planLabel = credential.plan.map { L10n.format("%@ plan", $0.capitalized) }
        return snapshot
    }

    // MARK: - Credentials

    static func readClaudeCodeCredentials() throws -> ClaudeOAuth {
        let item: Redacted<Data>?
        do {
            item = try Keychain.foreignItem(service: keychainService)
        } catch {
            throw UsageError.notConfigured(L10n.string("MyHub was not allowed to read Claude Code's sign-in."))
        }
        guard let item else {
            throw UsageError.notConfigured(L10n.string("Claude Code is not signed in on this Mac."))
        }
        guard let root = try? JSONSerialization.jsonObject(with: item.exposed) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError.notConfigured(L10n.string("Claude Code's sign-in is in a format MyHub does not recognise."))
        }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeOAuth(token: Redacted(token), expiresAt: expires, plan: oauth["subscriptionType"] as? String)
    }

    // MARK: - Parsing

    /// Known windows, in display order. The response carries many more keys
    /// (most of them null, several codenamed); anything not listed is ignored
    /// rather than guessed at.
    static let knownWindows: [(key: String, label: String)] = [
        ("five_hour", L10n.string("5-hour session")),
        ("seven_day", L10n.string("Weekly · all models")),
        ("seven_day_opus", L10n.string("Weekly · Opus")),
        ("seven_day_sonnet", L10n.string("Weekly · Sonnet")),
        ("seven_day_oauth_apps", L10n.string("Weekly · apps")),
    ]

    static func parse(_ data: Data, now: Date, accountID: String) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse("not a JSON object")
        }
        let windows: [QuotaWindow] = knownWindows.compactMap { key, label in
            guard let window = root[key] as? [String: Any],
                  let utilization = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return QuotaWindow(
                id: key, label: label,
                used: max(0, utilization / 100),
                resetsAt: (window["resets_at"] as? String).flatMap(ISODate.parse)
            )
        }
        guard !windows.isEmpty else { throw UsageError.badResponse("no usage windows") }

        var snapshot = UsageSnapshot(accountID: accountID, kind: .claudePlan, windows: windows, fidelity: .unofficial, fetchedAt: now)

        if let breakdown = root["seven_day_breakdown"] as? [String: Any],
           let rows = breakdown["rows"] as? [[String: Any]] {
            snapshot.shares = rows.compactMap { row in
                guard let name = row["display_name"] as? String,
                      let percent = (row["percent"] as? NSNumber)?.doubleValue, percent > 0 else { return nil }
                return Share(label: name, fraction: percent / 100)
            }
        }

        if let spend = root["spend"] as? [String: Any], spend["enabled"] as? Bool == true,
           let used = money(spend["used"]) {
            snapshot.spend = [SpendLine(label: L10n.string("Extra usage"), money: used, limit: money(spend["limit"]))]
        }
        return snapshot
    }

    /// `{ "amount_minor": 1234, "currency": "USD", "exponent": 2 }` → 12.34 USD.
    private static func money(_ value: Any?) -> Money? {
        guard let object = value as? [String: Any],
              let minor = (object["amount_minor"] as? NSNumber)?.int64Value,
              let currency = object["currency"] as? String else { return nil }
        let exponent = (object["exponent"] as? NSNumber)?.intValue ?? 2
        return Money(amount: Decimal(minor) / pow(10, exponent), currency: currency)
    }
}
