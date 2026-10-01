import Foundation
import Testing
@testable import MyHub

@Suite struct RedactedTests {
    let key = Redacted("sk-ant-admin01-SECRETVALUE-9f3a")

    @Test func neverPrintsTheValue() {
        #expect(!"\(key)".contains("SECRET"))
        #expect(!String(reflecting: key).contains("SECRET"))
        var dumped = ""
        dump(key, to: &dumped)
        #expect(!dumped.contains("SECRET"))
    }

    @Test func hintShowsOnlyTheTailOfLongKeys() {
        #expect(key.hint == "••••9f3a")
        #expect(Redacted("short").hint == "••••")
    }

    @Test func errorsWrappingItStayClean() {
        struct Failure: Error, CustomStringConvertible {
            let token: Redacted<String>
            var description: String { "request failed with \(token)" }
        }
        #expect(!"\(Failure(token: key))".contains("SECRET"))
    }
}

@MainActor
@Suite struct WriteCoalescerTests {
    @Test func manySchedulesBecomeOneWriteOfTheLatestState() async throws {
        let coalescer = WriteCoalescer(delay: .milliseconds(30))
        var written: [Int] = []
        for value in 1...5 { coalescer.schedule { written.append(value) } }
        // Wait for the write rather than for a fixed time: under a sanitizer
        // and a full parallel test run the main actor can be slow to get to it.
        let deadline = ContinuousClock.now + .seconds(2)
        while written.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(60))
        #expect(written == [5])
    }

    @Test func flushWritesImmediately() {
        let coalescer = WriteCoalescer(delay: .seconds(10))
        var written = 0
        coalescer.schedule { written += 1 }
        coalescer.flush()
        #expect(written == 1)
        #expect(!coalescer.hasPendingWrite)
    }

    @Test func cancelDropsThePendingWrite() async throws {
        let coalescer = WriteCoalescer(delay: .milliseconds(20))
        var written = 0
        coalescer.schedule { written += 1 }
        coalescer.cancel()
        try await Task.sleep(for: .milliseconds(80))
        #expect(written == 0)
    }
}
