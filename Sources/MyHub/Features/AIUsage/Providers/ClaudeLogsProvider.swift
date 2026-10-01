import Foundation

struct ClaudeUsageRecord: Sendable, Equatable {
    let timestamp: Date
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let write5m: Int
    let write1h: Int
}

/// Token usage from Claude Code's own logs (`~/.claude/projects/**/*.jsonl`).
/// Entirely local: no network, no credentials.
///
/// Claude Code writes one line per content block, repeating the message's
/// usage on each, and the output count grows while the reply streams. Counting
/// lines would roughly double the totals, so records are keyed by message id +
/// request id and the largest output wins.
struct ClaudeLogsProvider: UsageProvider {
    let accountID: String
    let ledger: LogLedger<ClaudeUsageRecord>
    var roots: [URL] = Self.defaultRoots()
    var prices: PriceTable = .standard
    var minimumInterval: TimeInterval { 15 }

    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent(".config/claude/projects"),
        ]
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            roots.insert(URL(fileURLWithPath: custom).appendingPathComponent("projects"), at: 0)
        }
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func makeLedger() -> LogLedger<ClaudeUsageRecord> {
        LogLedger(
            parse: { line, _, _ in parseLine(line) },
            merge: { $0.output >= $1.output ? $0 : $1 },
            timestamp: \.timestamp
        )
    }

    func fetch(now: Date) async throws -> UsageSnapshot {
        guard !roots.isEmpty else {
            throw UsageError.notConfigured(L10n.string("No Claude Code logs found in ~/.claude."))
        }
        let week = now.addingTimeInterval(-7 * 24 * 3600)
        let records = await ledger.scan(roots: roots, since: week)
        let today = Calendar.current.startOfDay(for: now)
        return UsageSnapshot(
            accountID: accountID,
            kind: .claudeLogs,
            tallies: [
                Self.tally(L10n.string("Last 5 hours"), records.filter { $0.timestamp >= now.addingTimeInterval(-5 * 3600) }, prices: prices),
                Self.tally(L10n.string("Today"), records.filter { $0.timestamp >= today }, prices: prices),
                Self.tally(L10n.string("Last 7 days"), records, prices: prices),
            ],
            daily: DailySeries.build(records.map { ($0.timestamp, $0.input + $0.output + $0.cacheRead + $0.write5m + $0.write1h) }, now: now),
            fidelity: .estimated,
            fetchedAt: now,
            note: L10n.string("Cost at API list prices")
        )
    }

    // MARK: - Pure pieces

    private struct Line: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                struct Creation: Decodable {
                    let ephemeral_5m_input_tokens: Int?
                    let ephemeral_1h_input_tokens: Int?
                }
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_read_input_tokens: Int?
                let cache_creation_input_tokens: Int?
                let cache_creation: Creation?
            }
            let id: String?
            let model: String?
            let usage: Usage?
        }
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    private static let usageMarker = Data(#""usage""#.utf8)

    static func parseLine(_ data: Data) -> (key: String, record: ClaudeUsageRecord)? {
        // Most lines are prompts, tool output and file contents: skip them
        // before paying for a JSON decode.
        guard data.range(of: usageMarker) != nil,
              let line = try? JSONDecoder().decode(Line.self, from: data),
              line.type == "assistant",
              let message = line.message, let usage = message.usage,
              let model = message.model, !model.hasPrefix("<"),
              let stamp = line.timestamp.flatMap(ISODate.parse) else { return nil }
        let created = usage.cache_creation_input_tokens ?? 0
        let w1h = usage.cache_creation?.ephemeral_1h_input_tokens ?? 0
        let w5m = usage.cache_creation?.ephemeral_5m_input_tokens ?? max(0, created - w1h)
        let record = ClaudeUsageRecord(
            timestamp: stamp, model: model,
            input: usage.input_tokens ?? 0, output: usage.output_tokens ?? 0,
            cacheRead: usage.cache_read_input_tokens ?? 0, write5m: w5m, write1h: w1h
        )
        guard record.input + record.output + record.cacheRead + w5m + w1h > 0 else { return nil }
        let key = [message.id, line.requestId].compactMap { $0 }.joined(separator: "|")
        return (key.isEmpty ? "\(stamp.timeIntervalSince1970)|\(model)" : key, record)
    }

    static func tally(_ label: String, _ records: [ClaudeUsageRecord], prices: PriceTable) -> TokenTally {
        var byModel: [String: (usage: ModelUsage, w5: Int, w1: Int)] = [:]
        for r in records {
            var entry = byModel[r.model] ?? (ModelUsage(model: r.model), 0, 0)
            entry.usage.input += r.input
            entry.usage.output += r.output
            entry.usage.cacheRead += r.cacheRead
            entry.usage.cacheWrite += r.write5m + r.write1h
            entry.w5 += r.write5m
            entry.w1 += r.write1h
            byModel[r.model] = entry
        }
        let models = byModel.values.map { entry -> ModelUsage in
            var usage = entry.usage
            usage.cost = prices.cost(model: usage.model, input: usage.input, output: usage.output,
                                     cacheRead: usage.cacheRead, write5m: entry.w5, write1h: entry.w1)
            return usage
        }
        .sorted { ($0.cost ?? 0, $0.totalTokens) > ($1.cost ?? 0, $1.totalTokens) }
        return TokenTally(label: label, models: models)
    }
}
