import Foundation

/// Amazon Bedrock usage.
///
/// Tokens: CloudWatch `GetMetricData` with a SEARCH over namespace
/// `AWS/Bedrock`, one series per `ModelId`, daily sums for the last week.
/// Cost (opt-in): Cost Explorer `GetCostAndUsage`, month to date, summed over
/// every service with "Bedrock" in its name — models sold through the AWS
/// Marketplace bill under their own service names. Cost Explorer charges
/// $0.01 per request, so it is asked at most once an hour.
///
/// Minimal IAM policy: `cloudwatch:GetMetricData`, plus `ce:GetCostAndUsage`
/// when cost is on.
struct BedrockProvider: UsageProvider {
    let accountID: String
    let region: String
    let includeCost: Bool
    var credentials: @Sendable () throws -> AWSCredentials
    var minimumInterval: TimeInterval { includeCost ? 3600 : 600 }

    static func isValidRegion(_ region: String) -> Bool {
        !region.isEmpty && region.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }

    func fetch(now: Date) async throws -> UsageSnapshot {
        guard Self.isValidRegion(region) else { throw UsageError.notConfigured(L10n.string("Invalid AWS region.")) }
        let credentials = try credentials()
        let host = "monitoring.\(region).amazonaws.com"
        var request = URLRequest(url: URL(string: "https://\(host)/")!)
        request.httpMethod = "POST"
        request.httpBody = Self.metricQuery(now: now)
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("GraniteServiceVersion20100801.GetMetricData", forHTTPHeaderField: "X-Amz-Target")
        let metrics = try await HTTPClient(allowedHosts: [host])
            .send(SigV4.sign(request, credentials: credentials, region: region, service: "monitoring", now: now))
        var snapshot = try Self.parseMetrics(metrics, now: now, accountID: accountID)
        snapshot.planLabel = region

        if includeCost {
            let ceHost = "ce.us-east-1.amazonaws.com"
            var ce = URLRequest(url: URL(string: "https://\(ceHost)/")!)
            ce.httpMethod = "POST"
            ce.httpBody = Self.costQuery(now: now)
            ce.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
            ce.setValue("AWSInsightsIndexService.GetCostAndUsage", forHTTPHeaderField: "X-Amz-Target")
            let cost = try await HTTPClient(allowedHosts: [ceHost])
                .send(SigV4.sign(ce, credentials: credentials, region: "us-east-1", service: "ce", now: now))
            if let month = Self.parseCost(cost) {
                snapshot.spend = [SpendLine(label: L10n.string("This month"), money: month, limit: nil)]
            }
        }
        return snapshot
    }

    static func metricQuery(now: Date) -> Data {
        func search(_ metric: String) -> String {
            "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"\(metric)\"', 'Sum', 86400)"
        }
        let body: [String: Any] = [
            "StartTime": UTCDay.startOfDay(now.addingTimeInterval(-6 * 86400)).timeIntervalSince1970,
            "EndTime": now.timeIntervalSince1970,
            "ScanBy": "TimestampAscending",
            "MetricDataQueries": [
                ["Id": "input", "Expression": search("InputTokenCount"), "ReturnData": true],
                ["Id": "output", "Expression": search("OutputTokenCount"), "ReturnData": true],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func parseMetrics(_ data: Data, now: Date, accountID: String) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["MetricDataResults"] as? [[String: Any]] else {
            throw UsageError.badResponse("no MetricDataResults")
        }
        let today = UTCDay.startOfDay(now)
        var week: [String: ModelUsage] = [:], day: [String: ModelUsage] = [:]
        var samples: [(date: Date, tokens: Int)] = []
        for result in results {
            let id = result["Id"] as? String ?? ""
            // SEARCH labels are the dimension value, sometimes with the metric name appended.
            let model = (result["Label"] as? String ?? "?")
                .replacingOccurrences(of: " InputTokenCount", with: "")
                .replacingOccurrences(of: " OutputTokenCount", with: "")
            let stamps = (result["Timestamps"] as? [NSNumber])?.map { Date(timeIntervalSince1970: $0.doubleValue) } ?? []
            let values = (result["Values"] as? [NSNumber])?.map(\.intValue) ?? []
            for (stamp, value) in zip(stamps, values) {
                samples.append((stamp.addingTimeInterval(3600), value))
                let add = { (usage: inout ModelUsage) in
                    if id.hasPrefix("input") { usage.input += value } else { usage.output += value }
                }
                add(&week[model, default: ModelUsage(model: model)])
                if stamp >= today { add(&day[model, default: ModelUsage(model: model)]) }
            }
        }
        let sort = { (a: ModelUsage, b: ModelUsage) in a.totalTokens > b.totalTokens }
        return UsageSnapshot(
            accountID: accountID, kind: .bedrock,
            tallies: [
                TokenTally(label: L10n.string("Today (UTC)"), models: day.values.sorted(by: sort)),
                TokenTally(label: L10n.string("Last 7 days"), models: week.values.sorted(by: sort)),
            ],
            daily: DailySeries.build(samples, now: now, calendar: UTCDay.calendar),
            fidelity: .official, fetchedAt: now
        )
    }

    static func costQuery(now: Date) -> Data {
        let calendar = UTCDay.calendar
        func day(_ date: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        let body: [String: Any] = [
            "TimePeriod": ["Start": day(UTCDay.startOfMonth(now)), "End": day(UTCDay.startOfDay(now).addingTimeInterval(86400))],
            "Granularity": "MONTHLY",
            "Metrics": ["UnblendedCost"],
            "GroupBy": [["Type": "DIMENSION", "Key": "SERVICE"]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func parseCost(_ data: Data) -> Money? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let periods = root["ResultsByTime"] as? [[String: Any]] else { return nil }
        var total = Decimal(0), unit = "USD", found = false
        for period in periods {
            for group in period["Groups"] as? [[String: Any]] ?? [] {
                guard let keys = group["Keys"] as? [String], keys.contains(where: { $0.localizedCaseInsensitiveContains("Bedrock") }),
                      let cost = (group["Metrics"] as? [String: Any])?["UnblendedCost"] as? [String: Any],
                      let amount = AnthropicAdminProvider.decimal(cost["Amount"]) else { continue }
                total += amount
                unit = cost["Unit"] as? String ?? unit
                found = true
            }
        }
        return found ? Money(amount: total, currency: unit) : Money(amount: 0, currency: unit)
    }
}
