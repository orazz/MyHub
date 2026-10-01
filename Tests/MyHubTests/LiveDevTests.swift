import Foundation
import Testing
@testable import MyHub

/// Opt-in: `MYHUB_LIVE=1 swift test --filter LiveDev` runs the real tools
/// (git, simctl) and asks GitHub's public API, unauthenticated, about a
/// public repository. Prints what it found.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MYHUB_LIVE"] == "1"))
struct LiveDevTests {
    @Test func gitStatusOfThisCheckout() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = try await CommandRunner.run("/usr/bin/git", ["-C", root.path, "status", "--porcelain=v2", "--branch"])
        #expect(out.succeeded, "\(out.failureReason)")
        let status = GitStatus.parse(out.stdout)
        print("LIVE git: branch \(status.branch ?? "-"), changed \(status.changed), untracked \(status.untracked)")
    }

    @Test func simulatorList() async throws {
        let out = try await CommandRunner.run(SimulatorStore.xcrun, ["simctl", "list", "devices", "--json"])
        let devices = try SimDevice.parse(Data(out.stdout.utf8))
        #expect(!devices.isEmpty)
        print("LIVE simctl: \(devices.count) devices, booted: \(devices.filter(\.isBooted).map(\.name))",
              "first: \(devices.prefix(3).map { "\($0.name) (\($0.runtime))" })")
    }

    @Test func publicWorkflowRuns() async throws {
        let repo = try #require(GitHubRepo(remote: "https://github.com/swiftlang/swift-format.git"))
        let runs = try await GitHubClient(token: nil).runs(repo, limit: 3)
        #expect(!runs.isEmpty)
        for run in runs { print("LIVE run: \(run.workflow) · \(run.title) · \(run.state) · \(run.url)") }
        let pull = try await GitHubClient(token: nil).pullRequest(repo, branch: "main")
        print("LIVE pull for main: \(pull.map { "#\($0.number)" } ?? "none")")
    }
}
