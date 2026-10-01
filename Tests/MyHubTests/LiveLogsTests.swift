import Foundation
import Testing
@testable import MyHub

/// Opt-in: `MYHUB_LIVE=1 swift test --filter LiveLogs` reads this Mac's real
/// Claude Code logs (local only, no network) and prints totals.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MYHUB_LIVE"] == "1"))
struct LiveLogsTests {
    @Test func claudeCodeLogsOnThisMac() async throws {
        let provider = ClaudeLogsProvider(accountID: "live", ledger: ClaudeLogsProvider.makeLedger())
        let clock = ContinuousClock()
        var snapshot: UsageSnapshot?
        let first = try await clock.measure { snapshot = try await provider.fetch(now: .now) }
        let second = try await clock.measure { _ = try await provider.fetch(now: .now) }
        for tally in snapshot?.tallies ?? [] {
            print("LIVE \(tally.label): \(UsageFormat.tokens(tally.totalTokens)) tokens, cost \(tally.cost.map { "\($0)" } ?? "-")",
                  tally.models.map { "\($0.model)=\(UsageFormat.tokens($0.totalTokens))" })
        }
        print("LIVE first scan \(first), incremental rescan \(second)")
    }
}
