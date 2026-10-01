import Foundation
import Testing
@testable import MyHub

@Suite struct TextToolTests {
    @Test func formatsAndMinifiesJSON() throws {
        let text = #"{"b":1,"a":[1,2]}"#
        #expect(TextTool.suggestions(for: text).contains(.formatJSON))
        let pretty = try #require(TextTool.formatJSON.apply(to: text))
        #expect(pretty.contains("\n"))
        #expect(pretty.firstRange(of: "\"a\"")!.lowerBound < pretty.firstRange(of: "\"b\"")!.lowerBound)
        let minified = try #require(TextTool.minifyJSON.apply(to: pretty))
        #expect(!minified.contains("\n") && !minified.contains(" "))
        #expect(JSONText.isJSON(minified))
    }

    @Test func decodesAJWTWithoutVerifyingIt() throws {
        // {"alg":"HS256","typ":"JWT"} . {"sub":"42","exp":1000000000}
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsImV4cCI6MTAwMDAwMDAwMH0.c2ln"
        #expect(TextTool.suggestions(for: token).first == .decodeJWT)
        let decoded = try #require(TextTool.decodeJWT.apply(to: token))
        #expect(decoded.contains("\"sub\" : \"42\""))
        #expect(decoded.contains("// expired"))
        #expect(decoded.contains("signature not verified"))
    }

    @Test func base64BothWaysIncludingURLSafe() {
        #expect(TextTool.base64Encode.apply(to: "hello world") == "aGVsbG8gd29ybGQ=")
        #expect(TextTool.base64Decode.apply(to: "aGVsbG8gd29ybGQ=") == "hello world")
        #expect(Base64Text.decode("aGVsbG8gd29ybGQ") == "hello world")
        // Ordinary words are not offered a Base64 decode.
        #expect(!TextTool.suggestions(for: "deployment").contains(.base64Decode))
    }

    @Test func urlCodingEscapesQueryCharacters() {
        #expect(TextTool.urlEncode.apply(to: "a b&c=d/e?") == "a%20b%26c%3Dd%2Fe%3F")
        #expect(TextTool.urlDecode.apply(to: "a%20b%26c") == "a b&c")
        #expect(TextTool.suggestions(for: "a%20b").contains(.urlDecode))
    }

    @Test func timestampsBothWays() throws {
        let seconds = try #require(TextTool.timestamp.apply(to: "1700000000"))
        #expect(seconds.hasPrefix("2023-11-14T22:13:20Z"))
        let millis = try #require(TextTool.timestamp.apply(to: "1700000000000"))
        #expect(millis.hasPrefix("2023-11-14T22:13:20Z"))
        #expect(TextTool.timestamp.apply(to: "2023-11-14T22:13:20Z") == "1700000000")
        #expect(TextTool.timestamp.apply(to: "12345") == nil)
    }

    @Test func hashesMatchKnownValues() {
        #expect(TextTool.sha256.apply(to: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(TextTool.md5.apply(to: "abc") == "900150983cd24fb0d6963f7d28e17f72")
    }

    @Test func hugeTextOnlyGetsHashes() {
        let big = String(repeating: "x", count: TextTool.maxInput + 1)
        #expect(TextTool.suggestions(for: big) == [.sha256, .uuid])
    }
}

@Suite struct GitParsingTests {
    @Test func parsesPorcelainV2() {
        let output = """
        # branch.oid 1a2b3c
        # branch.head feature/login
        # branch.upstream origin/feature/login
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 aaa bbb Sources/App.swift
        2 R. N... 100644 100644 100644 aaa bbb R100 New.swift\tOld.swift
        u UU N... 100644 100644 100644 100644 a b c Conflict.swift
        ? notes.txt
        ? other.txt
        """
        let status = GitStatus.parse(output)
        #expect(status.branch == "feature/login")
        #expect(status.upstream == "origin/feature/login")
        #expect(status.ahead == 2)
        #expect(status.behind == 1)
        #expect(status.changed == 2)
        #expect(status.conflicted == 1)
        #expect(status.untracked == 2)
        #expect(!status.isClean)
    }

    @Test func detachedHeadHasNoBranch() {
        #expect(GitStatus.parse("# branch.oid abc\n# branch.head (detached)\n").branch == nil)
        #expect(GitStatus.parse("# branch.head main\n").isClean)
    }

    @Test func readsGitHubRemotesOnly() {
        #expect(GitHubRepo(remote: "https://github.com/apple/swift.git")?.slug == "apple/swift")
        #expect(GitHubRepo(remote: "git@github.com:orazz/MyHub.git\n")?.slug == "orazz/MyHub")
        #expect(GitHubRepo(remote: "ssh://git@github.com/a/b")?.slug == "a/b")
        #expect(GitHubRepo(remote: "https://gitlab.com/a/b.git") == nil)
        #expect(GitHubRepo(remote: "https://github.com/a/b/c") == nil)
        #expect(GitHubRepo(remote: "https://github.com/../b") == nil)
        #expect(GitHubRepo(remote: "https://github.com/a/b%2F..") == nil)
    }

    @Test func checkStatesCombine() {
        #expect(CheckState(status: "in_progress", conclusion: nil) == .pending)
        #expect(CheckState(status: "completed", conclusion: "success") == .success)
        #expect(CheckState(status: "completed", conclusion: "timed_out") == .failure)
        #expect(CheckState(status: "completed", conclusion: "skipped") == .neutral)
        #expect(CheckState.combine([.success, .pending]) == .pending)
        #expect(CheckState.combine([.success, .failure, .pending]) == .failure)
        #expect(CheckState.combine([]) == nil)
    }

    @Test func decodesRunsAndRefusesForeignLinks() throws {
        let json = """
        {"total_count":2,"workflow_runs":[
          {"id":1,"name":"CI","display_title":"Fix login","head_branch":"main","event":"push","status":"in_progress",
           "conclusion":null,"html_url":"https://github.com/a/b/actions/runs/1","run_started_at":"2026-10-01T10:00:00Z",
           "created_at":"2026-10-01T10:00:00Z","updated_at":"2026-10-01T10:03:00Z"},
          {"id":2,"name":"CI","head_branch":"main","status":"completed","conclusion":"success",
           "html_url":"https://evil.example/runs/2","created_at":"2026-10-01T09:00:00Z","updated_at":"2026-10-01T09:05:00Z"}
        ]}
        """
        let repo = try #require(GitHubRepo(remote: "https://github.com/a/b"))
        let runs = try GitHubDecoding.runs(from: Data(json.utf8), repo: repo)
        #expect(runs.count == 1)
        #expect(runs[0].isRunning)
        #expect(runs[0].title == "Fix login")
        #expect(GitHubDecoding.safeWebURL("http://github.com/a") == nil)
        #expect(GitHubDecoding.safeWebURL("https://github.com.evil.example/a") == nil)
    }

    @Test func decodesThePullRequest() throws {
        let json = #"[{"number":7,"title":"Add login","html_url":"https://github.com/a/b/pull/7","draft":true,"head":{"sha":"abc"}}]"#
        let (pull, sha) = try #require(try GitHubDecoding.pull(from: Data(json.utf8)))
        #expect(pull.number == 7)
        #expect(pull.draft)
        #expect(sha == "abc")
        #expect(try GitHubDecoding.pull(from: Data("[]".utf8)) == nil)
        let checks = #"{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"queued","conclusion":null}]}"#
        #expect(try GitHubDecoding.checks(from: Data(checks.utf8)) == .pending)
    }
}

@Suite struct SimulatorParsingTests {
    @Test func bootedFirstThenNewestRuntime() throws {
        let json = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.iOS-17-5":[
            {"udid":"11111111-1111-1111-1111-111111111111","name":"iPhone 15","state":"Shutdown","isAvailable":true}],
          "com.apple.CoreSimulator.SimRuntime.iOS-18-2":[
            {"udid":"22222222-2222-2222-2222-222222222222","name":"iPhone 16","state":"Shutdown","isAvailable":true},
            {"udid":"33333333-3333-3333-3333-333333333333","name":"iPhone 16 Pro","state":"Booted","isAvailable":true},
            {"udid":"--evil","name":"Bad","state":"Booted","isAvailable":true},
            {"udid":"44444444-4444-4444-4444-444444444444","name":"Gone","state":"Shutdown","isAvailable":false}]
        }}
        """
        let devices = try SimDevice.parse(Data(json.utf8))
        #expect(devices.map(\.name) == ["iPhone 16 Pro", "iPhone 16", "iPhone 15"])
        #expect(devices[0].isBooted)
        #expect(devices[0].runtime == "iOS 18.2")
        #expect(SimDevice.runtimeLabel("com.apple.CoreSimulator.SimRuntime.watchOS-11-0") == "watchOS 11.0")
    }
}

@Suite struct FocusCycleTests {
    let lengths = FocusCycle.Lengths(work: 1500, shortBreak: 300, longBreak: 900, rounds: 2)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func phasesRunIntoEachOtherAutomatically() {
        var cycle = FocusCycle()
        #expect(cycle.isIdle)
        cycle.start(at: t0, lengths: lengths)
        #expect(cycle.remaining(at: t0.addingTimeInterval(600), lengths: lengths) == 900)
        #expect(cycle.isDue(at: t0.addingTimeInterval(1500)))
        #expect(cycle.finish(at: t0.addingTimeInterval(1500), lengths: lengths) == .work)
        #expect(cycle.phase == .shortBreak && cycle.isRunning)
        #expect(cycle.today(at: t0.addingTimeInterval(1500)).rounds == 1)
        #expect(cycle.today(at: t0.addingTimeInterval(1500)).focused == 1500)
        cycle.finish(at: t0.addingTimeInterval(1800), lengths: lengths)
        #expect(cycle.phase == .work && cycle.isRunning)
        #expect(cycle.round(lengths: lengths) == 2)
    }

    @Test func theLastRoundEarnsALongBreakThenTheCycleRestarts() {
        var cycle = FocusCycle()
        var now = t0
        cycle.start(at: now, lengths: lengths)
        for _ in 0..<3 {   // focus, short, focus
            now = cycle.endsAt!
            cycle.finish(at: now, lengths: lengths)
        }
        #expect(cycle.phase == .longBreak)
        #expect(cycle.round(lengths: lengths) == 2)
        #expect(cycle.roundFills(at: now, lengths: lengths) == [1, 1])
        now = cycle.endsAt!
        cycle.finish(at: now, lengths: lengths)
        #expect(cycle.phase == .work && cycle.round(lengths: lengths) == 1)
        #expect(cycle.roundFills(at: now, lengths: lengths) == [0, 0])
    }

    @Test func skipCountsTheTimeActuallySpent() {
        var cycle = FocusCycle()
        cycle.start(at: t0, lengths: lengths)
        cycle.finish(at: t0.addingTimeInterval(600), lengths: lengths)
        #expect(cycle.today(at: t0).focused == 600)
        #expect(cycle.phase == .shortBreak && cycle.isRunning)
        // From a stopped timer, skipping moves on but doesn't start.
        var stopped = FocusCycle()
        stopped.finish(at: t0, lengths: lengths)
        #expect(stopped.phase == .shortBreak && stopped.isIdle)
    }

    @Test func choosingAPhaseLoadsItPaused() {
        var cycle = FocusCycle()
        cycle.start(at: t0, lengths: lengths)
        cycle.select(.longBreak)
        #expect(cycle.isIdle && cycle.phase == .longBreak)
        #expect(cycle.remaining(at: t0, lengths: lengths) == 900)
    }

    @Test func pauseKeepsWhatWasLeftAndBarsFill() {
        var cycle = FocusCycle()
        cycle.start(at: t0, lengths: lengths)
        #expect(cycle.roundFills(at: t0.addingTimeInterval(750), lengths: lengths) == [0.5, 0])
        cycle.pause(at: t0.addingTimeInterval(100))
        #expect(cycle.isPaused)
        #expect(cycle.remaining(at: t0.addingTimeInterval(5000), lengths: lengths) == 1400)
        cycle.start(at: t0.addingTimeInterval(5000), lengths: lengths)
        #expect(cycle.remaining(at: t0.addingTimeInterval(5100), lengths: lengths) == 1300)
        cycle.reset()
        #expect(cycle.isIdle && cycle.phase == .work)
    }

    @Test func todayResetsAtMidnight() {
        var cycle = FocusCycle()
        cycle.start(at: t0, lengths: lengths)
        cycle.finish(at: t0.addingTimeInterval(1500), lengths: lengths)
        #expect(cycle.today(at: t0.addingTimeInterval(2 * 86400)).rounds == 0)
    }

    @Test func formats() {
        #expect(FocusCycle.clock(1500) == "25:00")
        #expect(FocusCycle.clock(59.2) == "1:00")
        #expect(FocusCycle.duration(1500) == "25m")
        #expect(FocusCycle.duration(4500) == "1h 15m")
    }

    @MainActor
    @Test func shortcutUsersKeepDoNotDisturbOn() throws {
        let named = try Preferences.decode(Data(#"{"focus": {"startShortcut": "Focus On"}}"#.utf8))
        #expect(named.focus.doNotDisturb)
        let none = try Preferences.decode(Data(#"{"focus": {"chime": false}}"#.utf8))
        #expect(!none.focus.doNotDisturb)
    }
}

@Suite struct SnippetTests {
    @Test func fillsPlaceholdersAndKeepsUnknownOnes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let text = SnippetExpander.expand("Hi {{clipboard}} at {{iso}} {{ uuid }} {{nope}} {single}",
                                          now: now, clipboard: "Ana", uuid: { id })
        #expect(text == "Hi Ana at 2023-11-14T22:13:20Z 00000000-0000-0000-0000-000000000001 {{nope}} {single}")
    }

    @Test func unterminatedBracesAreLeftAlone() {
        #expect(SnippetExpander.expand("a {{date b") == "a {{date b")
        #expect(SnippetExpander.expand("plain") == "plain")
    }

    @MainActor
    @Test func storeSavesAndSweepsEmptySnippets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubSnippets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("snippets.json")
        let store = SnippetStore(file: file, saveDelay: .milliseconds(1))
        store.add()
        let keep = try #require(store.selectedID)
        store.update(keep, title: "Reply", body: "Thanks, {{clipboard}}!")
        store.add()
        store.sweep()
        #expect(store.snippets.count == 1)
        #expect(SnippetStore(file: file).snippets.first?.title == "Reply")
    }
}

@Suite struct RulerGeometryTests {
    @Test func dragsInAnyDirectionGiveTheSameRect() {
        let a = RulerGeometry.rect(from: CGPoint(x: 10.4, y: 50), to: CGPoint(x: 110.2, y: 20))
        let b = RulerGeometry.rect(from: CGPoint(x: 110.2, y: 20), to: CGPoint(x: 10.4, y: 50))
        #expect(a == b)
        #expect(a == CGRect(x: 10, y: 20, width: 100, height: 30))
    }

    @Test func labelsShowPixelsOnRetina() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 48)
        #expect(RulerGeometry.label(for: rect, scale: 2) == "320 × 48 pt · 640 × 96 px")
        #expect(RulerGeometry.label(for: rect, scale: 1) == "320 × 48 pt")
        #expect(RulerGeometry.copyText(for: rect) == "320×48")
    }

    @Test func pointsMapToFlippedPixels() {
        let pixel = RulerGeometry.pixel(for: CGPoint(x: 10, y: 990), viewHeight: 1000, scale: 2)
        #expect(pixel.x == 20 && pixel.y == 20)
    }

    @Test func loupeStaysInsideTheImage() {
        let region = RulerGeometry.loupeRegion(around: (1, 1), radius: 5, imageSize: (100, 100))
        #expect(region == CGRect(x: 0, y: 0, width: 11, height: 11))
        let corner = RulerGeometry.loupeRegion(around: (99, 99), radius: 5, imageSize: (100, 100))
        #expect(corner.maxX == 100 && corner.maxY == 100)
    }

    @Test func labelsFlipAtTheEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        let origin = RulerGeometry.labelOrigin(near: CGPoint(x: 490, y: 5), size: CGSize(width: 100, height: 20), bounds: bounds)
        #expect(origin.x + 100 <= 500)
        #expect(origin.y >= 0)
        #expect(RulerGeometry.hex(red: 255, green: 16, blue: 0) == "#FF1000")
    }
}

@Suite struct DevSafetyTests {
    @Test func cleanupOnlyTouchesTheLibrary() {
        #expect(CleanupTarget.all.allSatisfy { $0.isSafe })
        let rogue = CleanupTarget(id: "x", title: "", detail: "", folders: [URL(fileURLWithPath: "/Users")], action: .deleteContents)
        #expect(!rogue.isSafe)
    }

    @Test func screenshotsAreRecognisedByTheirTag() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString).png")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!ScreenshotWatcher.isScreenshot(file))
        // What screencapture writes: a binary plist holding `true`.
        let value = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let set = value.withUnsafeBytes { setxattr(file.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, value.count, 0, 0) }
        #expect(set == 0)
        #expect(ScreenshotWatcher.isScreenshot(file))
    }

    @Test func commandsRunWithoutAShellAndTimeOut() async throws {
        let echo = try await CommandRunner.run("/bin/echo", ["$HOME; rm -rf /"])
        #expect(echo.stdout == "$HOME; rm -rf /\n")
        let started = Date()
        let slow = try await CommandRunner.run("/bin/sleep", ["10"], timeout: .milliseconds(300))
        #expect(!slow.succeeded)
        #expect(Date().timeIntervalSince(started) < 5)
        await #expect(throws: CommandRunner.Failure.self) {
            try await CommandRunner.run("/nonexistent/tool", [])
        }
    }

    @MainActor
    @Test func oldPreferenceFilesGetTheNewSections() throws {
        let values = try Preferences.decode(Data(#"{"general": {"openOnHover": false}}"#.utf8))
        #expect(values.focus.workMinutes == 25)
        #expect(values.dev.watchCI)
        #expect(!values.design.collectScreenshots)
        #expect(values.design.rulerShortcut == .ruler)
    }
}
