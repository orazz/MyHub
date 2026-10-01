import Foundation
import Testing
@testable import MyHub

// Shapes mirror live responses captured on 2026-09-30, with synthetic values.

@Suite struct ISODateTests {
    @Test(arguments: [
        "2026-09-30T20:30:00.130999+00:00",
        "2026-09-30T20:30:00.130Z",
        "2026-09-30T20:30:00Z",
        "2026-09-30T20:30:00+00:00",
    ])
    func parsesTheVariantsAPIsSend(_ text: String) throws {
        let date = try #require(ISODate.parse(text))
        #expect(abs(date.timeIntervalSince1970 - 1_790_800_200) < 1)
    }
}

@Suite struct ClaudePlanParsingTests {
    let fixture = Data("""
    {
      "five_hour": {"utilization": 27.0, "resets_at": "2026-09-30T20:30:00.130999+00:00", "limit_dollars": null, "used_dollars": null, "remaining_dollars": null, "locked_reason": null},
      "seven_day": {"utilization": 4.0, "resets_at": "2026-10-05T17:00:00.131021+00:00"},
      "seven_day_opus": null, "seven_day_sonnet": null,
      "nimbus_quill": {"utilization": 0.0, "resets_at": null},
      "extra_usage": {"is_enabled": false},
      "limits": [{"kind": "session", "group": "session", "percent": 27, "severity": "normal", "resets_at": "2026-09-30T20:30:00.130999+00:00", "scope": null, "is_active": true}],
      "spend": {"used": {"amount_minor": 0, "currency": "USD", "exponent": 2}, "limit": null, "percent": 0, "enabled": false},
      "seven_day_breakdown": {"as_of": "2026-09-30T16:18:52.184164+00:00", "rows": [
        {"key": "claude_code", "display_name": "Claude Code", "percent": 93},
        {"key": "chat", "display_name": "Chats", "percent": 0},
        {"key": "other", "display_name": "Other", "percent": 7}
      ]}
    }
    """.utf8)

    @Test func readsKnownWindowsAndIgnoresCodenames() throws {
        let snapshot = try ClaudePlanProvider.parse(fixture, now: .now, accountID: "a")
        #expect(snapshot.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(snapshot.windows[0].used == 0.27)
        #expect(snapshot.windows[0].resetsAt != nil)
        #expect(snapshot.fidelity == .unofficial)
    }

    @Test func readsTheBreakdownWithoutEmptyRows() throws {
        let snapshot = try ClaudePlanProvider.parse(fixture, now: .now, accountID: "a")
        #expect(snapshot.shares.map(\.label) == ["Claude Code", "Other"])
    }

    @Test func disabledSpendIsNotShown() throws {
        #expect(try ClaudePlanProvider.parse(fixture, now: .now, accountID: "a").spend.isEmpty)
    }

    @Test func enabledSpendUsesMinorUnits() throws {
        let data = Data(#"{"five_hour": {"utilization": 1}, "spend": {"enabled": true, "used": {"amount_minor": 1234, "currency": "USD", "exponent": 2}, "limit": {"amount_minor": 5000, "currency": "USD", "exponent": 2}}}"#.utf8)
        let line = try #require(try ClaudePlanProvider.parse(data, now: .now, accountID: "a").spend.first)
        #expect(line.money == Money(amount: Decimal(string: "12.34")!, currency: "USD"))
        #expect(line.limit?.amount == 50)
    }

    @Test func aResponseWithoutWindowsIsAnError() {
        #expect(throws: UsageError.self) {
            try ClaudePlanProvider.parse(Data(#"{"error": "nope"}"#.utf8), now: .now, accountID: "a")
        }
    }

    @Test func expiredCredentialsNeverReachTheNetwork() async {
        let provider = ClaudePlanProvider(accountID: "a", credentials: {
            ClaudeOAuth(token: Redacted("x"), expiresAt: Date(timeIntervalSince1970: 0), plan: "pro")
        })
        await #expect(throws: UsageError.self) { try await provider.fetch(now: .now) }
    }
}

@Suite struct ClaudeLogsTests {
    func line(id: String, request: String = "req_1", output: Int, model: String = "claude-opus-5-5",
              at time: String = "2026-09-30T15:34:26.414Z") -> String {
        #"{"type":"assistant","timestamp":"\#(time)","requestId":"\#(request)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":2,"output_tokens":\#(output),"cache_read_input_tokens":1000,"cache_creation_input_tokens":500,"cache_creation":{"ephemeral_1h_input_tokens":500,"ephemeral_5m_input_tokens":0}},"content":[]}}"#
    }

    @Test func parsesAnAssistantLine() throws {
        let parsed = try #require(ClaudeLogsProvider.parseLine(Data(line(id: "msg_1", output: 343).utf8)))
        #expect(parsed.key == "msg_1|req_1")
        #expect(parsed.record.output == 343)
        #expect(parsed.record.write1h == 500)
        #expect(parsed.record.write5m == 0)
    }

    @Test func ignoresNonAssistantAndSyntheticLines() {
        #expect(ClaudeLogsProvider.parseLine(Data(#"{"type":"user","message":{"content":"usage"}}"#.utf8)) == nil)
        #expect(ClaudeLogsProvider.parseLine(Data(line(id: "m", output: 0, model: "<synthetic>").utf8)) == nil)
    }

    @Test func ledgerDedupesStreamedLinesAndReadsIncrementally() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubLogs-\(UUID().uuidString)/project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("session.jsonl")
        let since = Date(timeIntervalSince1970: 0)
        let ledger = ClaudeLogsProvider.makeLedger()

        // Same message three times (content blocks), output growing, plus a
        // line still being written.
        let first = [line(id: "msg_1", output: 10), line(id: "msg_1", output: 300), line(id: "msg_1", output: 300)]
            .joined(separator: "\n") + "\n" + String(line(id: "msg_2", output: 50).prefix(40))
        try Data(first.utf8).write(to: file)
        var records = await ledger.scan(roots: [folder.deletingLastPathComponent()], since: since)
        #expect(records.count == 1)
        #expect(records.first?.output == 300)

        // The partial line completes and a new message arrives.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(line(id: "msg_2", output: 50).dropFirst(40)) + "\n" + line(id: "msg_3", output: 7) + "\n").utf8))
        try handle.close()
        records = await ledger.scan(roots: [folder.deletingLastPathComponent()], since: since)
        #expect(records.map(\.output).sorted() == [7, 50, 300])
    }

    @Test func tallyPricesKnownModelsAndFlagsUnknownOnes() {
        let records = [
            ClaudeUsageRecord(timestamp: .now, model: "claude-opus-5-5", input: 1_000_000, output: 0, cacheRead: 0, write5m: 0, write1h: 0),
            ClaudeUsageRecord(timestamp: .now, model: "claude-future-9", input: 10, output: 10, cacheRead: 0, write5m: 0, write1h: 0),
        ]
        let tally = ClaudeLogsProvider.tally("Today", records, prices: PriceTable(entries: PriceTable.anthropicDefaults))
        #expect(tally.cost == 4)
        #expect(tally.costIsPartial)
        #expect(tally.totalTokens == 1_000_020)
    }
}

@Suite struct PriceTableTests {
    let table = PriceTable(entries: PriceTable.anthropicDefaults)

    @Test func longestPrefixWins() {
        #expect(table.price(for: "claude-opus-5-5")?.input == 4)
        #expect(table.price(for: "claude-opus-5")?.input == 5)
        #expect(table.price(for: "claude-haiku-4-5-20251001")?.input == 1)
        #expect(table.price(for: "claude-fable-5-1")?.cacheRead == Decimal(string: "0.25"))
        #expect(table.price(for: "gpt-5") == nil)
    }

    @Test func cacheWritesUseTheirMultipliers() {
        // Sonnet 5.5: input $2 → 5m write $2.50, 1h write $4, read $0.20 (per MTok).
        let cost = table.cost(model: "claude-sonnet-5-5", input: 0, output: 0, cacheRead: 1_000_000, write5m: 1_000_000, write1h: 1_000_000)
        #expect(cost == Decimal(string: "6.7"))
    }
}

@Suite struct CodexTests {
    @Test func parsesPlanWindows() throws {
        let data = Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":42.5,"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":1790800200},"secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1791300000}}}"#.utf8)
        let snapshot = try CodexPlanProvider.parse(data, now: .now, accountID: "c")
        #expect(snapshot.windows.map(\.label) == ["5-hour window", "Weekly"])
        #expect(snapshot.windows[0].used == 0.425)
        #expect(snapshot.planLabel == "ChatGPT Plus")
    }

    @Test func readsAuthButRejectsAPIKeyMode() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubCodex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"OPENAI_API_KEY":"sk-xyz","tokens":null}"#.utf8).write(to: home.appendingPathComponent("auth.json"))
        #expect(throws: UsageError.self) { try CodexPlanProvider.readCodexAuth(home: home) }
        try Data(#"{"tokens":{"access_token":"eyJ.secret","account_id":"acct_1"}}"#.utf8).write(to: home.appendingPathComponent("auth.json"))
        let auth = try CodexPlanProvider.readCodexAuth(home: home)
        #expect(auth.accountID == "acct_1")
        #expect(!"\(auth.token)".contains("secret"))
    }

    @Test func logLinesCarryModelFromContextAndLimits() throws {
        var context: [String: String] = [:]
        #expect(CodexLogsProvider.parseLine(Data(#"{"type":"turn_context","payload":{"model":"gpt-5-codex"}}"#.utf8), &context, "f") == nil)
        let event = #"{"timestamp":"2026-09-30T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1500},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":300,"reasoning_output_tokens":200}},"rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_in_seconds":600},"secondary":{"used_percent":3.0,"window_minutes":10080}}}}"#
        let parsed = try #require(CodexLogsProvider.parseLine(Data(event.utf8), &context, "f"))
        #expect(parsed.record.model == "gpt-5-codex")
        #expect(parsed.record.input == 600)
        #expect(parsed.record.cachedInput == 400)
        #expect(parsed.record.output == 500)
        #expect(parsed.record.primary?.used == 0.12)
        #expect(parsed.record.primary?.resetsAt == parsed.record.timestamp.addingTimeInterval(600))
        #expect(CodexWindows.label(seconds: 10080 * 60, fallback: "secondary") == "Weekly")
    }
}

@Suite struct BackoffTests {
    let now = Date(timeIntervalSinceReferenceDate: 0)

    @Test func successWaitsTheMinimumInterval() {
        var backoff = Backoff()
        backoff.succeeded(at: now, minimumInterval: 300)
        #expect(!backoff.allows(now.addingTimeInterval(299)))
        #expect(backoff.allows(now.addingTimeInterval(300)))
    }

    @Test func failuresGrowExponentiallyToACap() {
        var backoff = Backoff()
        var waits: [TimeInterval] = []
        for _ in 0..<10 {
            backoff.failed(at: now, retryAfter: nil, jitter: 0)
            waits.append(backoff.notBefore.timeIntervalSince(now))
        }
        #expect(Array(waits.prefix(4)) == [30, 60, 120, 240])
        #expect(waits.last == Backoff.cap)
    }

    @Test func retryAfterIsHonoured() {
        var backoff = Backoff()
        backoff.failed(at: now, retryAfter: 900, jitter: 0)
        #expect(backoff.notBefore == now.addingTimeInterval(900))
    }
}

private actor CallCounter {
    var count = 0
    func hit() { count += 1 }
}

private struct FakeProvider: UsageProvider {
    let accountID: String
    let counter: CallCounter
    var fails = false
    var minimumInterval: TimeInterval { 300 }

    func fetch(now: Date) async throws -> UsageSnapshot {
        await counter.hit()
        if fails { throw UsageError.rateLimited(retryAfter: 60) }
        return UsageSnapshot(accountID: accountID, kind: .claudeLogs, fidelity: .estimated, fetchedAt: now)
    }
}

@Suite struct UsageEngineTests {
    @Test func respectsTheMinimumIntervalUnlessForced() async {
        let counter = CallCounter()
        let engine = UsageEngine(jitter: { 0 })
        let provider = FakeProvider(accountID: "a", counter: counter)
        let now = Date()
        _ = await engine.refresh([provider], now: now, force: false)
        let second = await engine.refresh([provider], now: now.addingTimeInterval(10), force: false)
        #expect(second.first?.skipped == true)
        _ = await engine.refresh([provider], now: now.addingTimeInterval(20), force: true)
        #expect(await counter.count == 2)
    }

    @Test func forceNeverOverridesBackoffAfterAFailure() async {
        let counter = CallCounter()
        let engine = UsageEngine(jitter: { 0 })
        let provider = FakeProvider(accountID: "a", counter: counter, fails: true)
        let now = Date()
        let first = await engine.refresh([provider], now: now, force: true)
        #expect(first.first?.result == .failure(.rateLimited(retryAfter: 60)))
        _ = await engine.refresh([provider], now: now.addingTimeInterval(5), force: true)
        #expect(await counter.count == 1)
    }

    @Test func oneFailingSourceDoesNotBlockOthers() async {
        let engine = UsageEngine(jitter: { 0 })
        let outcomes = await engine.refresh([
            FakeProvider(accountID: "bad", counter: CallCounter(), fails: true),
            FakeProvider(accountID: "good", counter: CallCounter()),
        ], now: Date(), force: false)
        let good = outcomes.first { $0.accountID == "good" }
        if case .success = good?.result {} else { Issue.record("good source did not succeed") }
    }
}

@Suite struct HTTPClientTests {
    let client = HTTPClient(allowedHosts: ["api.anthropic.com"])

    @Test func allowsOnlyListedHostsOverHTTPS() throws {
        try client.validate(URL(string: "https://api.anthropic.com/api/oauth/usage"))
        #expect(throws: UsageError.self) { try client.validate(URL(string: "https://evil.example/x")) }
        #expect(throws: UsageError.self) { try client.validate(URL(string: "http://api.anthropic.com/x")) }
        #expect(throws: UsageError.self) { try client.validate(URL(string: "https://user:pw@api.anthropic.com/x")) }
    }

    @Test func loopbackHTTPOnlyWhenAllowed() throws {
        var local = HTTPClient(allowedHosts: ["localhost"])
        #expect(throws: UsageError.self) { try local.validate(URL(string: "http://localhost:4000/key/info")) }
        local.allowsLoopbackHTTP = true
        try local.validate(URL(string: "http://localhost:4000/key/info"))
    }
}

@Suite struct UsageFormatTests {
    @Test func formatsTokensAndModelNames() {
        #expect(UsageFormat.tokens(950) == "950")
        #expect(UsageFormat.tokens(36_268) == "36.3K")
        #expect(UsageFormat.tokens(1_250_000) == "1.2M")
        #expect(UsageFormat.model("claude-opus-5-5") == "opus 5.5")
        #expect(UsageFormat.model("claude-haiku-4-5-20251001") == "haiku 4.5")
        #expect(UsageFormat.model("gpt-5-codex") == "gpt-5-codex")
    }
}

@MainActor
@Suite struct UsageStoreTests {
    func store() -> UsageStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubUsage-\(UUID().uuidString).json")
        return UsageStore(preferences: Preferences(file: file), refreshesOnAdd: false)
    }

    @Test func severalSourcesCanBeAddedOneAfterAnother() {
        let usage = store()
        usage.add(.claudeLogs)
        usage.add(.claudePlan)
        usage.add(.codexLogs)
        #expect(usage.accounts.map(\.kind) == [.claudeLogs, .claudePlan, .codexLogs])
    }

    @Test func aLocalSourceIsNotAddedTwiceAndShowsAsAdded() {
        let usage = store()
        usage.add(.claudeLogs)
        usage.add(.claudeLogs)
        #expect(usage.accounts.count == 1)
        #expect(usage.sourceChoices.first { $0.kind == .claudeLogs }?.added == true)
        #expect(usage.sourceChoices.first { $0.kind == .claudePlan }?.added == false)
    }

    @Test func unavailableSourcesCannotBeAddedYet() {
        let usage = store()
        usage.add(.bedrock)
        #expect(usage.accounts.isEmpty)
    }

    @Test func removingFreesTheSlot() throws {
        let usage = store()
        usage.add(.claudeLogs)
        usage.remove(try #require(usage.accounts.first?.id))
        usage.add(.claudeLogs)
        #expect(usage.accounts.count == 1)
    }
}
