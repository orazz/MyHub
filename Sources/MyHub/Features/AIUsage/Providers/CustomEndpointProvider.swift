import Foundation

/// Reads a value out of decoded JSON by a tiny path language: dot-separated
/// keys and `[index]`, with `|` for alternatives (`info.spend|spend`).
/// Nothing else — no expressions, no scripting — so a path typed into
/// Settings can never do more than look.
enum JSONPath {
    static func value(_ path: String, in root: Any) -> Any? {
        for alternative in path.split(separator: "|") {
            if let found = walk(alternative.trimmingCharacters(in: .whitespaces), in: root), !(found is NSNull) {
                return found
            }
        }
        return nil
    }

    private static func walk(_ path: String, in root: Any) -> Any? {
        var current: Any? = root
        for segment in path.split(separator: ".", omittingEmptySubsequences: true) {
            var name = Substring(segment)
            var indexes: [Int] = []
            while let open = name.lastIndex(of: "["), name.hasSuffix("]"),
                  let index = Int(name[name.index(after: open)..<name.index(before: name.endIndex)]) {
                indexes.insert(index, at: 0)
                name = name[..<open]
            }
            if !name.isEmpty { current = (current as? [String: Any])?[String(name)] }
            for index in indexes {
                guard let array = current as? [Any], array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        return current
    }

    static func number(_ path: String, in root: Any) -> Double? {
        switch value(path, in: root) {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }

    static func date(_ path: String, in root: Any) -> Date? {
        switch value(path, in: root) {
        case let number as NSNumber:
            // Seconds or milliseconds since 1970.
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
        case let string as String:
            return ISODate.parse(string)
        default:
            return nil
        }
    }
}

struct CustomEndpointConfig: Sendable, Equatable {
    enum Preset: String, Sendable { case litellm, generic }

    var preset: Preset = .litellm
    var url: String = ""
    var authHeader: String = "Authorization"
    var bearer = true
    var percentPath = ""
    var usedPath = ""
    var limitPath = ""
    var spendPath = ""
    var resetPath = ""
    var currency = "USD"

    /// LiteLLM's `/key/info` puts the numbers under `info`; some versions
    /// return them at the top level, hence the alternatives.
    static func litellm(baseURL: String) -> CustomEndpointConfig {
        var config = CustomEndpointConfig()
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        config.url = base.hasSuffix("/key/info") ? base : base + "/key/info"
        config.spendPath = "info.spend|spend"
        config.limitPath = "info.max_budget|max_budget"
        config.usedPath = "info.spend|spend"
        config.resetPath = "info.budget_reset_at|budget_reset_at"
        return config
    }

    init() {}

    init(options: [String: String]) {
        preset = Preset(rawValue: options["preset"] ?? "") ?? .generic
        url = options["url"] ?? ""
        authHeader = options["authHeader"] ?? "Authorization"
        bearer = options["bearer"] != "false"
        percentPath = options["percentPath"] ?? ""
        usedPath = options["usedPath"] ?? ""
        limitPath = options["limitPath"] ?? ""
        spendPath = options["spendPath"] ?? ""
        resetPath = options["resetPath"] ?? ""
        currency = options["currency"].flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
    }

    var options: [String: String] {
        ["preset": preset.rawValue, "url": url, "authHeader": authHeader, "bearer": bearer ? "true" : "false",
         "percentPath": percentPath, "usedPath": usedPath, "limitPath": limitPath,
         "spendPath": spendPath, "resetPath": resetPath, "currency": currency]
    }

    /// HTTPS anywhere; plain HTTP only to this Mac (a local proxy).
    var client: HTTPClient? {
        guard let parsed = URL(string: url), let host = parsed.host?.lowercased() else { return nil }
        var client = HTTPClient(allowedHosts: [host])
        client.allowsLoopbackHTTP = true
        return (try? client.validate(parsed)) == nil ? nil : client
    }
}

/// Any JSON endpoint: a LiteLLM proxy, a company gateway, a self-built
/// budget service. The user maps which fields mean what.
struct CustomEndpointProvider: UsageProvider {
    let accountID: String
    let config: CustomEndpointConfig
    var key: @Sendable () throws -> Redacted<String>?
    var minimumInterval: TimeInterval { 120 }

    func fetch(now: Date) async throws -> UsageSnapshot {
        guard let url = URL(string: config.url), let client = config.client else {
            throw UsageError.refused(L10n.string("The URL must be HTTPS (plain HTTP only for localhost)."))
        }
        var headers = ["Accept": "application/json"]
        if let secret = try key(), !secret.isEmpty, !config.authHeader.isEmpty {
            headers[config.authHeader] = config.bearer ? "Bearer \(secret.exposed)" : secret.exposed
        }
        let data = try await client.get(url, headers: headers)
        return try Self.parse(data, config: config, now: now, accountID: accountID)
    }

    static func parse(_ data: Data, config: CustomEndpointConfig, now: Date, accountID: String) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw UsageError.badResponse("not JSON") }
        func path(_ value: String) -> String? { value.isEmpty ? nil : value }
        var snapshot = UsageSnapshot(accountID: accountID, kind: .custom, fidelity: .official, fetchedAt: now)
        let reset = path(config.resetPath).flatMap { JSONPath.date($0, in: root) }

        if let percent = path(config.percentPath).flatMap({ JSONPath.number($0, in: root) }) {
            snapshot.windows = [QuotaWindow(id: "percent", label: L10n.string("Used"), used: max(0, percent > 1 ? percent / 100 : percent), resetsAt: reset)]
        } else if let used = path(config.usedPath).flatMap({ JSONPath.number($0, in: root) }),
                  let limit = path(config.limitPath).flatMap({ JSONPath.number($0, in: root) }), limit > 0 {
            snapshot.windows = [QuotaWindow(id: "budget", label: L10n.string("Budget"), used: max(0, used / limit), resetsAt: reset)]
        }
        if let spend = path(config.spendPath).flatMap({ JSONPath.number($0, in: root) }) {
            let limit = path(config.limitPath).flatMap { JSONPath.number($0, in: root) }
            snapshot.spend = [SpendLine(
                label: L10n.string("Spend"),
                money: Money(amount: Decimal(spend), currency: config.currency),
                limit: limit.map { Money(amount: Decimal($0), currency: config.currency) }
            )]
        }
        guard !snapshot.windows.isEmpty || !snapshot.spend.isEmpty else {
            throw UsageError.badResponse(L10n.string("none of the mapped fields were found"))
        }
        return snapshot
    }
}
