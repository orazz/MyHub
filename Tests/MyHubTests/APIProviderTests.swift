import Foundation
import Testing
@testable import MyHub

// Fixtures follow the documented response shapes (Anthropic / OpenAI API
// references, OpenRouter limits docs, LiteLLM /key/info), values synthetic.

@Suite struct AnthropicAdminTests {
    let now = ISODate.parse("2026-09-30T15:00:00Z")!

    let costs = Data("""
    {"data":[
      {"starting_at":"2026-09-29T00:00:00Z","ending_at":"2026-09-30T00:00:00Z","results":[{"amount":"1250.5","currency":"USD","description":null}]},
      {"starting_at":"2026-09-30T00:00:00Z","ending_at":"2026-10-01T00:00:00Z","results":[{"amount":"123.45","currency":"USD"}]}
    ],"has_more":false,"next_page":null}
    """.utf8)

    let usage = Data("""
    {"data":[
      {"starting_at":"2026-09-29T00:00:00Z","ending_at":"2026-09-30T00:00:00Z","results":[
        {"model":"claude-opus-5-5","uncached_input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":2000,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20},"server_tool_use":{"web_search_requests":0}}]},
      {"starting_at":"2026-09-30T00:00:00Z","ending_at":"2026-10-01T00:00:00Z","results":[
        {"model":"claude-opus-5-5","uncached_input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}},
        {"model":"claude-haiku-4-5","uncached_input_tokens":7,"output_tokens":3,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}]}
    ],"has_more":false,"next_page":null}
    """.utf8)

    @Test func costsAreCentStringsSummedForMonthAndToday() throws {
        let snapshot = try AnthropicAdminProvider.snapshot(costPages: [costs], usage: usage, now: now, accountID: "a")
        #expect(snapshot.spend.map(\.label) == ["Today", "This month"])
        #expect(snapshot.spend[0].money.amount == Decimal(string: "1.2345"))
        #expect(snapshot.spend[1].money.amount == Decimal(string: "13.7395"))
        #expect(snapshot.fidelity == .official)
    }

    @Test func tokensByModelForTodayAndTheWeek() throws {
        let snapshot = try AnthropicAdminProvider.snapshot(costPages: [costs], usage: usage, now: now, accountID: "a")
        let week = try #require(snapshot.tallies.last)
        let opus = try #require(week.models.first { $0.model == "claude-opus-5-5" })
        #expect(opus.input == 1100)
        #expect(opus.cacheWrite == 30)
        #expect(snapshot.tallies.first?.models.count == 2)
    }

    @Test func followsPagination() {
        #expect(AnthropicAdminProvider.nextPage(Data(#"{"data":[],"has_more":true,"next_page":"page_x"}"#.utf8)) == "page_x")
        #expect(AnthropicAdminProvider.nextPage(costs) == nil)
    }
}

@Suite struct OpenAIAdminTests {
    let now = Date(timeIntervalSince1970: 1_790_780_400) // 2026-09-30 15:00 UTC

    @Test func sumsCostsWhetherNumbersOrStrings() throws {
        let costs = Data("""
        {"object":"page","data":[
          {"object":"bucket","start_time":1790640000,"end_time":1790726400,"results":[{"object":"organization.costs.result","amount":{"value":0.06,"currency":"usd"},"line_item":null,"project_id":null}]},
          {"object":"bucket","start_time":1790726400,"end_time":1790812800,"results":[{"object":"organization.costs.result","amount":{"value":"1.50","currency":"usd"}}]}
        ],"has_more":false,"next_page":null}
        """.utf8)
        let usage = Data("""
        {"object":"page","data":[{"object":"bucket","start_time":1790726400,"end_time":1790812800,"results":[
          {"object":"organization.usage.completions.result","input_tokens":1000,"input_cached_tokens":400,"output_tokens":500,"num_model_requests":5,"model":"gpt-5"}]}],"has_more":false}
        """.utf8)
        let snapshot = try OpenAIAdminProvider.snapshot(costs: costs, usage: usage, now: now, accountID: "o")
        #expect(snapshot.spend[0].money == Money(amount: Decimal(string: "1.5")!, currency: "USD"))
        #expect(snapshot.spend[1].money.amount == Decimal(string: "1.56"))
        let gpt = try #require(snapshot.tallies.first?.models.first)
        #expect(gpt.input == 600)
        #expect(gpt.cacheRead == 400)
        #expect(gpt.output == 500)
    }
}

@Suite struct OpenRouterTests {
    @Test func spendLinesAndKeyLimit() throws {
        let data = Data("""
        {"data":{"label":"sk-or-v1-abc...xyz","limit":20,"limit_reset":"monthly","limit_remaining":15,"include_byok_in_limit":false,
          "usage":42.5,"usage_daily":1.25,"usage_weekly":4,"usage_monthly":5,"is_free_tier":false,"rate_limit":{"requests":-1,"interval":"10s"}}}
        """.utf8)
        let snapshot = try OpenRouterProvider.parse(data, now: .now, accountID: "r")
        #expect(snapshot.spend.map(\.label) == ["Today", "This week", "This month", "All time"])
        #expect(snapshot.spend[0].money.amount == Decimal(string: "1.25"))
        #expect(snapshot.windows.first?.used == 0.25)
        #expect(snapshot.windows.first?.label == "Key limit (monthly)")
    }

    @Test func unlimitedKeyHasNoWindow() throws {
        let snapshot = try OpenRouterProvider.parse(Data(#"{"data":{"limit":null,"usage":1,"is_free_tier":true}}"#.utf8), now: .now, accountID: "r")
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.planLabel == "Free tier")
    }
}

@Suite struct CustomEndpointTests {
    @Test func jsonPathWalksKeysIndexesAndAlternatives() throws {
        let root = try JSONSerialization.jsonObject(with: Data(#"{"a":{"b":[{"c":5},{"c":"7"}]},"top":1,"nil":null}"#.utf8))
        #expect(JSONPath.number("a.b[0].c", in: root) == 5)
        #expect(JSONPath.number("a.b[1].c", in: root) == 7)
        #expect(JSONPath.number("missing|top", in: root) == 1)
        #expect(JSONPath.number("nil|top", in: root) == 1)
        #expect(JSONPath.number("a.b[9].c", in: root) == nil)
    }

    @Test func litellmPresetReadsInfoOrTopLevel() throws {
        let config = CustomEndpointConfig.litellm(baseURL: "https://proxy.example.com/")
        #expect(config.url == "https://proxy.example.com/key/info")
        let nested = Data(#"{"key":"hashed","info":{"spend":3.5,"max_budget":10,"budget_reset_at":"2026-10-01T00:00:00Z"}}"#.utf8)
        let flat = Data(#"{"spend":3.5,"max_budget":10}"#.utf8)
        for data in [nested, flat] {
            let snapshot = try CustomEndpointProvider.parse(data, config: config, now: .now, accountID: "x")
            #expect(snapshot.windows.first?.used == 0.35)
            #expect(snapshot.spend.first?.limit?.amount == 10)
        }
    }

    @Test func genericPercentAcceptsZeroToOneOrZeroToHundred() throws {
        var config = CustomEndpointConfig()
        config.preset = .generic
        config.percentPath = "usage.pct"
        let hundred = try CustomEndpointProvider.parse(Data(#"{"usage":{"pct":42}}"#.utf8), config: config, now: .now, accountID: "x")
        let fraction = try CustomEndpointProvider.parse(Data(#"{"usage":{"pct":0.42}}"#.utf8), config: config, now: .now, accountID: "x")
        #expect(hundred.windows.first?.used == 0.42)
        #expect(fraction.windows.first?.used == 0.42)
    }

    @Test func unmappedResponseIsAnError() {
        var config = CustomEndpointConfig()
        config.spendPath = "nope"
        #expect(throws: UsageError.self) {
            try CustomEndpointProvider.parse(Data(#"{"x":1}"#.utf8), config: config, now: .now, accountID: "x")
        }
    }

    @Test func httpOnlyForLocalhost() {
        var config = CustomEndpointConfig()
        config.url = "http://localhost:4000/key/info"
        #expect(config.client != nil)
        config.url = "http://proxy.example.com/key/info"
        #expect(config.client == nil)
        config.url = "https://proxy.example.com/key/info"
        #expect(config.client?.allowedHosts == ["proxy.example.com"])
    }

    @Test func optionsRoundTrip() {
        var config = CustomEndpointConfig()
        config.preset = .generic
        config.url = "https://x.example/usage"
        config.bearer = false
        config.spendPath = "a.b"
        #expect(CustomEndpointConfig(options: config.options) == config)
    }
}

@Suite struct BedrockTests {
    let now = ISODate.parse("2026-09-30T15:00:00Z")!

    @Test func metricQueryUsesSearchPerModel() throws {
        let body = try #require(try JSONSerialization.jsonObject(with: BedrockProvider.metricQuery(now: now)) as? [String: Any])
        let queries = try #require(body["MetricDataQueries"] as? [[String: Any]])
        #expect(queries.compactMap { $0["Expression"] as? String }.allSatisfy { $0.contains("{AWS/Bedrock,ModelId}") })
    }

    @Test func parsesDailySeriesPerModel() throws {
        let today = UTCDay.startOfDay(now).timeIntervalSince1970
        let data = Data("""
        {"MetricDataResults":[
          {"Id":"input","Label":"anthropic.claude-opus-5-5","Timestamps":[\(today - 86400),\(today)],"Values":[1000,200],"StatusCode":"Complete"},
          {"Id":"output","Label":"anthropic.claude-opus-5-5 OutputTokenCount","Timestamps":[\(today)],"Values":[50],"StatusCode":"Complete"}
        ]}
        """.utf8)
        let snapshot = try BedrockProvider.parseMetrics(data, now: now, accountID: "b")
        let todayModel = try #require(snapshot.tallies.first?.models.first)
        #expect(todayModel.model == "anthropic.claude-opus-5-5")
        #expect(todayModel.input == 200)
        #expect(todayModel.output == 50)
        #expect(snapshot.tallies.last?.totalTokens == 1250)
    }

    @Test func costSumsEveryBedrockService() {
        let data = Data("""
        {"ResultsByTime":[{"TimePeriod":{"Start":"2026-09-01","End":"2026-10-01"},"Groups":[
          {"Keys":["Amazon Bedrock"],"Metrics":{"UnblendedCost":{"Amount":"12.50","Unit":"USD"}}},
          {"Keys":["Claude Opus 5.5 (Amazon Bedrock Edition)"],"Metrics":{"UnblendedCost":{"Amount":"7.25","Unit":"USD"}}},
          {"Keys":["Amazon EC2"],"Metrics":{"UnblendedCost":{"Amount":"99","Unit":"USD"}}}]}]}
        """.utf8)
        #expect(BedrockProvider.parseCost(data) == Money(amount: Decimal(string: "19.75")!, currency: "USD"))
    }

    @Test func readsStaticProfilesAndRejectsSSO() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubAWS-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".aws"), withIntermediateDirectories: true)
        try "[default]\naws_access_key_id = AKIATEST\naws_secret_access_key = s3cr3t\n# comment\n[work]\naws_access_key_id=AK2\n"
            .write(to: home.appendingPathComponent(".aws/credentials"), atomically: true, encoding: .utf8)
        try "[profile sso-dev]\nsso_start_url = https://x.awsapps.com/start\n"
            .write(to: home.appendingPathComponent(".aws/config"), atomically: true, encoding: .utf8)
        let credentials = try AWSCredentialSource.profile("default", home: home)
        #expect(credentials.accessKeyID == "AKIATEST")
        #expect(!"\(credentials.secret)".contains("s3cr3t"))
        #expect(throws: UsageError.self) { try AWSCredentialSource.profile("sso-dev", home: home) }
        #expect(throws: UsageError.self) { try AWSCredentialSource.profile("work", home: home) }
    }
}

@MainActor
@Suite struct SourceSetupTests {
    func store() -> (UsageStore, SecretBox) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubSetup-\(UUID().uuidString).json")
        let usage = UsageStore(preferences: Preferences(file: file), refreshesOnAdd: false)
        let box = SecretBox()
        usage.storeSecret = { secret, account in box.saved[account] = secret.exposed }
        return (usage, box)
    }

    final class SecretBox { var saved: [String: String] = [:] }

    @Test func keyBasedSourcesOpenAFormInsteadOfAddingBlind() {
        let (usage, _) = store()
        usage.choose(.openRouter)
        #expect(usage.draft?.kind == .openRouter)
        #expect(usage.accounts.isEmpty)
    }

    @Test func savingPutsTheKeyInTheSecretStoreNotPreferences() throws {
        let (usage, box) = store()
        usage.choose(.anthropicAdmin)
        usage.draft?.secret = "  sk-ant-admin01-SECRET  "
        usage.saveDraft()
        let account = try #require(usage.accounts.first)
        #expect(box.saved[account.id] == "sk-ant-admin01-SECRET")
        #expect(!String(describing: account).contains("SECRET"))
        #expect(usage.draft == nil)
    }

    @Test func anEmptyKeyIsRefusedWithAReason() {
        let (usage, box) = store()
        usage.choose(.openAIAdmin)
        usage.saveDraft()
        #expect(usage.accounts.isEmpty)
        #expect(usage.draftError != nil)
        #expect(box.saved.isEmpty)
    }

    @Test func warnsWhenTheKeyIsNotAnAdminKey() {
        var draft = SourceDraft(kind: .anthropicAdmin)
        draft.secret = "sk-ant-api03-regular"
        #expect(draft.warning != nil)
        draft.secret = "sk-ant-admin01-x"
        #expect(draft.warning == nil)
    }

    @Test func bedrockProfileNeedsNoSecretAndStoresOptions() throws {
        let (usage, box) = store()
        usage.choose(.bedrock)
        usage.draft?.useProfile = true
        usage.draft?.region = "eu-west-1"
        usage.saveDraft()
        let account = try #require(usage.accounts.first)
        #expect(account.options["region"] == "eu-west-1")
        #expect(account.options["credentials"] == "profile")
        #expect(box.saved.isEmpty)
    }

    @Test func customEndpointRejectsPlainHTTPToTheInternet() {
        let (usage, _) = store()
        usage.choose(.custom)
        usage.draft?.url = "http://proxy.example.com"
        usage.saveDraft()
        #expect(usage.accounts.isEmpty)
        usage.draft?.url = "https://proxy.example.com"
        usage.saveDraft()
        #expect(usage.accounts.first?.options["url"] == "https://proxy.example.com/key/info")
    }

    @Test func apiSourcesCanBeAddedMoreThanOnce() {
        let (usage, _) = store()
        for _ in 0..<2 {
            usage.choose(.openRouter)
            usage.draft?.secret = "sk-or-v1-x"
            usage.saveDraft()
        }
        #expect(usage.accounts.count == 2)
    }
}
