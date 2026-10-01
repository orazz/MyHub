import Foundation

/// Calendar arithmetic in UTC: the admin APIs bucket by UTC day.
enum UTCDay {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
    }

    static func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    static func rfc3339(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon).timeZone(separator: .omitted))
    }
}

/// Anthropic organisation usage and cost, from the documented Usage & Cost
/// Admin API. Needs an Admin key; regular API keys are rejected by the API.
///
/// Costs come back as decimal strings in **cents** ("123.45" = $1.23).
struct AnthropicAdminProvider: UsageProvider {
    let accountID: String
    var key: @Sendable () throws -> Redacted<String>
    /// The API supports a request a minute; ten minutes is plenty for a glance.
    var minimumInterval: TimeInterval { 600 }

    static let host = "api.anthropic.com"

    func fetch(now: Date) async throws -> UsageSnapshot {
        let secret = try key()
        let http = HTTPClient(allowedHosts: [Self.host])
        let headers = ["x-api-key": secret.exposed, "anthropic-version": "2023-06-01", "Accept": "application/json"]

        let monthStart = UTCDay.startOfMonth(now)
        var costPages: [Data] = []
        var page: String?
        repeat {
            var components = URLComponents(string: "https://\(Self.host)/v1/organizations/cost_report")!
            components.queryItems = [
                .init(name: "starting_at", value: UTCDay.rfc3339(monthStart)),
                .init(name: "bucket_width", value: "1d"),
                .init(name: "limit", value: "31"),
            ] + (page.map { [.init(name: "page", value: $0)] } ?? [])
            let data = try await http.get(components.url!, headers: headers)
            costPages.append(data)
            page = Self.nextPage(data)
        } while page != nil && costPages.count < 3

        var usage = URLComponents(string: "https://\(Self.host)/v1/organizations/usage_report/messages")!
        usage.queryItems = [
            .init(name: "starting_at", value: UTCDay.rfc3339(UTCDay.startOfDay(now.addingTimeInterval(-6 * 86400)))),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "7"),
            .init(name: "group_by[]", value: "model"),
        ]
        let usageData = try await http.get(usage.url!, headers: headers)
        return try Self.snapshot(costPages: costPages, usage: usageData, now: now, accountID: accountID)
    }

    static func nextPage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["has_more"] as? Bool == true else { return nil }
        return object["next_page"] as? String
    }

    static func snapshot(costPages: [Data], usage: Data, now: Date, accountID: String) throws -> UsageSnapshot {
        let today = UTCDay.startOfDay(now)
        var month = Decimal(0), day = Decimal(0), currency = "USD"
        for page in costPages {
            for bucket in try buckets(page) {
                let start = (bucket["starting_at"] as? String).flatMap(ISODate.parse) ?? .distantPast
                for result in bucket["results"] as? [[String: Any]] ?? [] {
                    guard let cents = decimal(result["amount"]) else { continue }
                    currency = result["currency"] as? String ?? currency
                    month += cents / 100
                    if start >= today { day += cents / 100 }
                }
            }
        }
        var week: [String: ModelUsage] = [:], todayUsage: [String: ModelUsage] = [:]
        var samples: [(date: Date, tokens: Int)] = []
        for bucket in try buckets(usage) {
            let start = (bucket["starting_at"] as? String).flatMap(ISODate.parse) ?? .distantPast
            for result in bucket["results"] as? [[String: Any]] ?? [] {
                let fields = ["uncached_input_tokens", "output_tokens", "cache_read_input_tokens"]
                let written = (result["cache_creation"] as? [String: Any]).map {
                    (($0["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0) + (($0["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0)
                } ?? 0
                samples.append((start.addingTimeInterval(3600), fields.reduce(written) { $0 + ((result[$1] as? NSNumber)?.intValue ?? 0) }))
                let model = result["model"] as? String ?? L10n.string("All models")
                let creation = result["cache_creation"] as? [String: Any] ?? [:]
                func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
                let add = { (usage: inout ModelUsage) in
                    usage.input += int(result["uncached_input_tokens"])
                    usage.output += int(result["output_tokens"])
                    usage.cacheRead += int(result["cache_read_input_tokens"])
                    usage.cacheWrite += int(creation["ephemeral_5m_input_tokens"]) + int(creation["ephemeral_1h_input_tokens"])
                }
                add(&week[model, default: ModelUsage(model: model)])
                if start >= today { add(&todayUsage[model, default: ModelUsage(model: model)]) }
            }
        }
        let sort = { (a: ModelUsage, b: ModelUsage) in a.totalTokens > b.totalTokens }
        return UsageSnapshot(
            accountID: accountID, kind: .anthropicAdmin,
            spend: [
                SpendLine(label: L10n.string("Today"), money: Money(amount: day, currency: currency), limit: nil),
                SpendLine(label: L10n.string("This month"), money: Money(amount: month, currency: currency), limit: nil),
            ],
            tallies: [
                TokenTally(label: L10n.string("Today"), models: todayUsage.values.sorted(by: sort)),
                TokenTally(label: L10n.string("Last 7 days"), models: week.values.sorted(by: sort)),
            ],
            daily: DailySeries.build(samples, now: now, calendar: UTCDay.calendar),
            fidelity: .official, fetchedAt: now,
            note: L10n.string("Cost data can lag by a few minutes")
        )
    }

    static func buckets(_ data: Data) throws -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = object["data"] as? [[String: Any]] else { throw UsageError.badResponse("no data buckets") }
        return buckets
    }

    /// Numbers arrive as JSON numbers or as decimal strings.
    static func decimal(_ value: Any?) -> Decimal? {
        if let string = value as? String { return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) }
        if let number = value as? NSNumber { return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")) }
        return nil
    }
}

/// OpenAI organisation costs and completion usage, from the documented
/// Usage and Costs Admin API. Needs an Admin key (`sk-admin-…`).
struct OpenAIAdminProvider: UsageProvider {
    let accountID: String
    var key: @Sendable () throws -> Redacted<String>
    var minimumInterval: TimeInterval { 600 }

    static let host = "api.openai.com"

    func fetch(now: Date) async throws -> UsageSnapshot {
        let secret = try key()
        let http = HTTPClient(allowedHosts: [Self.host])
        let headers = ["Authorization": "Bearer \(secret.exposed)", "Accept": "application/json"]

        var costs = URLComponents(string: "https://\(Self.host)/v1/organization/costs")!
        costs.queryItems = [
            .init(name: "start_time", value: String(Int(UTCDay.startOfMonth(now).timeIntervalSince1970))),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "31"),
        ]
        var usage = URLComponents(string: "https://\(Self.host)/v1/organization/usage/completions")!
        usage.queryItems = [
            .init(name: "start_time", value: String(Int(UTCDay.startOfDay(now.addingTimeInterval(-6 * 86400)).timeIntervalSince1970))),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "7"),
            .init(name: "group_by", value: "model"),
        ]
        async let costData = http.get(costs.url!, headers: headers)
        async let usageData = http.get(usage.url!, headers: headers)
        return try Self.snapshot(costs: try await costData, usage: try await usageData, now: now, accountID: accountID)
    }

    static func snapshot(costs: Data, usage: Data, now: Date, accountID: String) throws -> UsageSnapshot {
        let today = UTCDay.startOfDay(now)
        var month = Decimal(0), day = Decimal(0), currency = "USD"
        for bucket in try AnthropicAdminProvider.buckets(costs) {
            let start = (bucket["start_time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .distantPast
            for result in bucket["results"] as? [[String: Any]] ?? [] {
                let amount = result["amount"] as? [String: Any]
                guard let value = AnthropicAdminProvider.decimal(amount?["value"]) else { continue }
                currency = (amount?["currency"] as? String)?.uppercased() ?? currency
                month += value
                if start >= today { day += value }
            }
        }
        var week: [String: ModelUsage] = [:], todayUsage: [String: ModelUsage] = [:]
        var samples: [(date: Date, tokens: Int)] = []
        for bucket in try AnthropicAdminProvider.buckets(usage) {
            let start = (bucket["start_time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .distantPast
            for result in bucket["results"] as? [[String: Any]] ?? [] {
                samples.append((start.addingTimeInterval(3600),
                                ((result["input_tokens"] as? NSNumber)?.intValue ?? 0) + ((result["output_tokens"] as? NSNumber)?.intValue ?? 0)))
                let model = result["model"] as? String ?? L10n.string("All models")
                func int(_ key: String) -> Int { (result[key] as? NSNumber)?.intValue ?? 0 }
                let cached = int("input_cached_tokens")
                let add = { (usage: inout ModelUsage) in
                    usage.input += max(0, int("input_tokens") - cached)
                    usage.cacheRead += cached
                    usage.output += int("output_tokens")
                }
                add(&week[model, default: ModelUsage(model: model)])
                if start >= today { add(&todayUsage[model, default: ModelUsage(model: model)]) }
            }
        }
        let sort = { (a: ModelUsage, b: ModelUsage) in a.totalTokens > b.totalTokens }
        return UsageSnapshot(
            accountID: accountID, kind: .openAIAdmin,
            spend: [
                SpendLine(label: L10n.string("Today"), money: Money(amount: day, currency: currency), limit: nil),
                SpendLine(label: L10n.string("This month"), money: Money(amount: month, currency: currency), limit: nil),
            ],
            tallies: [
                TokenTally(label: L10n.string("Today"), models: todayUsage.values.sorted(by: sort)),
                TokenTally(label: L10n.string("Last 7 days"), models: week.values.sorted(by: sort)),
            ],
            daily: DailySeries.build(samples, now: now, calendar: UTCDay.calendar),
            fidelity: .official, fetchedAt: now
        )
    }
}

/// OpenRouter credit use for one key: daily / weekly / monthly spend, and the
/// key's own limit when it has one.
struct OpenRouterProvider: UsageProvider {
    let accountID: String
    var key: @Sendable () throws -> Redacted<String>
    var minimumInterval: TimeInterval { 300 }

    static let host = "openrouter.ai"

    func fetch(now: Date) async throws -> UsageSnapshot {
        let secret = try key()
        let data = try await HTTPClient(allowedHosts: [Self.host]).get(
            URL(string: "https://openrouter.ai/api/v1/key")!,
            headers: ["Authorization": "Bearer \(secret.exposed)", "Accept": "application/json"]
        )
        return try Self.parse(data, now: now, accountID: accountID)
    }

    static func parse(_ data: Data, now: Date, accountID: String) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = root["data"] as? [String: Any] else { throw UsageError.badResponse("no data") }
        func dollars(_ name: String) -> Money? {
            AnthropicAdminProvider.decimal(key[name]).map { Money(amount: $0, currency: "USD") }
        }
        var snapshot = UsageSnapshot(accountID: accountID, kind: .openRouter, fidelity: .official, fetchedAt: now)
        let label = key["label"] as? String
        snapshot.planLabel = (key["is_free_tier"] as? Bool == true) ? L10n.string("Free tier") : label
        snapshot.spend = [("usage_daily", L10n.string("Today")), ("usage_weekly", L10n.string("This week")),
                          ("usage_monthly", L10n.string("This month")), ("usage", L10n.string("All time"))]
            .compactMap { field, title in dollars(field).map { SpendLine(label: title, money: $0, limit: nil) } }
        if let limit = (key["limit"] as? NSNumber)?.doubleValue, limit > 0 {
            let remaining = (key["limit_remaining"] as? NSNumber)?.doubleValue ?? limit
            let reset = key["limit_reset"] as? String
            snapshot.windows = [QuotaWindow(
                id: "limit",
                label: reset.map { L10n.format("Key limit (%@)", $0) } ?? L10n.string("Key limit"),
                used: max(0, (limit - remaining) / limit),
                resetsAt: nil
            )]
        }
        return snapshot
    }
}
