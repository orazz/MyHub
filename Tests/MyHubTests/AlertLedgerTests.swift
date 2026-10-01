import Foundation
import Testing
@testable import MyHub

@Suite struct AlertLedgerTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let account = UsageAccount(id: "acct", kind: .claudePlan, label: "Claude plan")

    func items(_ used: Double, reset offset: TimeInterval = 3600, jitter: TimeInterval = 0) -> [(account: UsageAccount, snapshot: UsageSnapshot)] {
        let window = QuotaWindow(id: "five_hour", label: "5-hour session", used: used, resetsAt: now.addingTimeInterval(offset + jitter))
        return [(account, UsageSnapshot(accountID: "acct", kind: .claudePlan, windows: [window], fidelity: .unofficial, fetchedAt: now))]
    }

    @Test func quietBelowTheFirstThreshold() {
        var ledger = AlertLedger()
        #expect(ledger.evaluate(items(0.79), now: now).isEmpty)
    }

    @Test func alertsOncePerThresholdPerPeriod() {
        var ledger = AlertLedger()
        #expect(ledger.evaluate(items(0.81), now: now).count == 1)
        #expect(ledger.evaluate(items(0.85, jitter: 0.4), now: now).isEmpty)
        let high = ledger.evaluate(items(0.96), now: now)
        #expect(high.count == 1)
        #expect(high.first?.title.contains("96%") == true)
        #expect(ledger.evaluate(items(0.99), now: now).isEmpty)
    }

    @Test func aBigJumpSendsOneAlertNotTwo() {
        var ledger = AlertLedger()
        #expect(ledger.evaluate(items(0.97), now: now).count == 1)
        #expect(ledger.evaluate(items(0.82), now: now).isEmpty)
    }

    @Test func aNewPeriodCanAlertAgain() {
        var ledger = AlertLedger()
        _ = ledger.evaluate(items(0.9), now: now)
        #expect(ledger.evaluate(items(0.9, reset: 5 * 3600), now: now).count == 1)
    }

    @Test func bodySaysWhenItResets() {
        var ledger = AlertLedger()
        #expect(ledger.evaluate(items(0.8), now: now).first?.body == "5-hour session is at 80%. Resets in 1 h.")
    }
}
