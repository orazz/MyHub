import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import MyHub

@Suite struct ClipKindTests {
    @Test(arguments: [
        ("https://developer.apple.com/documentation/swiftui/", ClipKind.link),
        ("rm -rf ~/Library/Developer/Xcode/DerivedData", .code),
        ("let x = foo(); return x;", .code),
        ("#E8A94A", .color(hex: "E8A94A")),
        ("#fa0", .color(hex: "FFAA00")),
        ("facade", .text),
        ("Ship the notch build Friday, QA on Thursday", .text),
        ("/usr/local/bin/swift", .code),
    ])
    func classifies(_ text: String, _ expected: ClipKind) {
        #expect(ClipKind.classify(text) == expected)
    }

    @Test func imageFilesGetThePhotoIcon() {
        #expect(ClipKind.classify(.files([URL(fileURLWithPath: "/tmp/a.png")])) == .files(images: true))
        #expect(ClipKind.classify(.files([URL(fileURLWithPath: "/tmp/a.pdf")])).symbol == "doc")
    }

    @Test func relativeTimeIsShort() {
        let now = Date()
        #expect(ClipFormat.ago(now.addingTimeInterval(-20), now: now) == "now")
        #expect(ClipFormat.ago(now.addingTimeInterval(-240), now: now) == "4m")
        #expect(ClipFormat.ago(now.addingTimeInterval(-3 * 3600), now: now) == "3h")
    }
}

@Suite struct NoteTextTests {
    let text = "Notch build checklist\n- [x] Bump version to 1.4\n- [ ] Check drag-out animation\n\nPlain line"

    @Test func parsesTasksTextAndGaps() {
        let body = NoteText.body(of: text)
        #expect(body == [
            .task(index: 1, text: "Bump version to 1.4", done: true),
            .task(index: 2, text: "Check drag-out animation", done: false),
            .gap(index: 3),
            .text(index: 4, text: "Plain line"),
        ])
    }

    @Test func togglingRewritesOnlyThatLine() {
        let toggled = NoteText.toggling(text, line: 2)
        #expect(toggled.contains("- [x] Check drag-out animation"))
        #expect(NoteText.toggling(toggled, line: 1).contains("- [ ] Bump version"))
        #expect(NoteText.toggling(text, line: 0) == text)
    }

    @Test func titleLineIsSkippedEvenAfterBlankLines() {
        #expect(NoteText.body(of: "\n\nTitle\n- [ ] a").first == .task(index: 3, text: "a", done: false))
    }
}

@Suite struct CalendarRedesignTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }

    @Test func nextWorkdaySkipsTheWeekend() throws {
        let friday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 15)))
        let next = AgendaFormat.nextWorkday(after: friday, calendar: calendar)
        #expect(calendar.component(.weekday, from: next) == 2) // Monday
    }

    @Test func weekStripMarksTodayAndWeekends() throws {
        let wednesday = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12)))
        let week = AgendaFormat.week(of: wednesday, calendar: calendar)
        #expect(week.map(\.number) == [28, 29, 30, 1, 2, 3, 4])
        #expect(week.filter(\.isToday).map(\.number) == [30])
        #expect(week.filter(\.isWeekend).map(\.number) == [3, 4])
    }

    @Test func shortDurations() {
        #expect(AgendaFormat.shortDuration(30 * 60) == "30m")
        #expect(AgendaFormat.shortDuration(3600) == "1h")
        #expect(AgendaFormat.shortDuration(90 * 60) == "1h 30m")
    }
}

@Suite struct UsageRedesignTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func dailySeriesIsSevenDaysEndingToday() {
        let calendar = Calendar.current
        let series = DailySeries.build([(now, 10), (now.addingTimeInterval(-86400), 5), (now.addingTimeInterval(-30 * 86400), 99)], now: now)
        #expect(series.count == 7)
        #expect(series.last?.tokens == 10)
        #expect(series[5].tokens == 5)
        #expect(series.map(\.tokens).reduce(0, +) == 15)
        #expect(calendar.isDate(series.last!.day, inSameDayAs: now))
    }

    @Test func groupsClaudeAndChatGPTSourcesTogether() {
        let accounts = [
            UsageAccount(id: "1", kind: .claudePlan, label: "Claude plan"),
            UsageAccount(id: "2", kind: .openRouter, label: "OpenRouter"),
            UsageAccount(id: "3", kind: .claudeLogs, label: "Claude Code"),
            UsageAccount(id: "4", kind: .openAIAdmin, label: "OpenAI"),
        ]
        let groups = UsageGroup.build(accounts)
        #expect(groups.map(\.title) == ["Claude", "ChatGPT", "OpenRouter"])
        #expect(groups[0].accounts.map(\.id) == ["1", "3"])
    }

    @Test func summaryTakesWindowsFromThePlanAndTokensFromTheLogs() {
        let group = UsageGroup(id: "claude", title: "Claude", accounts: [
            UsageAccount(id: "plan", kind: .claudePlan, label: "Claude plan"),
            UsageAccount(id: "logs", kind: .claudeLogs, label: "Claude Code"),
        ])
        let daily = DailySeries.build([(now, 1_200_000)], now: now)
        let snapshots = [
            "plan": UsageSnapshot(accountID: "plan", kind: .claudePlan, planLabel: "Max plan", windows: [
                QuotaWindow(id: "five_hour", label: "5-hour", used: 0.62, resetsAt: now.addingTimeInterval(6480)),
                QuotaWindow(id: "seven_day", label: "Weekly", used: 0.34, resetsAt: nil),
            ], fidelity: .unofficial, fetchedAt: now),
            "logs": UsageSnapshot(accountID: "logs", kind: .claudeLogs, daily: daily, fidelity: .estimated, fetchedAt: now),
        ]
        let summary = UsageSummary.build(group: group, snapshots: snapshots, errors: [:])
        #expect(summary.session?.value == "62%")
        #expect(summary.session?.title == "Current session")
        #expect(summary.weekly?.value == "34%")
        #expect(summary.todayTokens == 1_200_000)
        #expect(summary.plan == "Max plan")
    }

    @Test func apiOnlySourcesShowSpendInsteadOfWindows() {
        let group = UsageGroup(id: "r", title: "OpenRouter", accounts: [UsageAccount(id: "r", kind: .openRouter, label: "OpenRouter")])
        let snapshot = UsageSnapshot(accountID: "r", kind: .openRouter, spend: [
            SpendLine(label: "Today", money: Money(amount: 1.25, currency: "USD"), limit: nil),
            SpendLine(label: "This month", money: Money(amount: 5, currency: "USD"), limit: nil),
        ], fidelity: .official, fetchedAt: now)
        let summary = UsageSummary.build(group: group, snapshots: ["r": snapshot], errors: ["r": .unauthorized])
        #expect(summary.session?.title == "Today")
        #expect(summary.weekly?.title == "This month")
        #expect(summary.session?.progress == nil)
        #expect(summary.problems.count == 1)
    }
}

@Suite struct BuildsTests {
    /// Shape of a real LogStoreManifest.plist entry (values synthetic).
    let manifest = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>logFormatVersion</key><integer>11</integer>
      <key>logs</key><dict>
        <key>A1</key><dict>
          <key>title</key><string>Building workspace Runner with scheme Runner and configuration Debug</string>
          <key>schemeIdentifier-schemeName</key><string>Runner</string>
          <key>timeStartedRecording</key><real>804691665.04</real>
          <key>timeStoppedRecording</key><real>804691739.67</real>
          <key>primaryObservable</key><dict><key>highLevelStatus</key><string>S</string><key>totalNumberOfErrors</key><integer>0</integer></dict>
        </dict>
        <key>B2</key><dict>
          <key>title</key><string>Building project Orbit with scheme Orbit</string>
          <key>schemeIdentifier-schemeName</key><string>Orbit</string>
          <key>timeStartedRecording</key><real>804700000</real>
          <key>timeStoppedRecording</key><real>804700030</real>
          <key>primaryObservable</key><dict><key>highLevelStatus</key><string>E</string><key>totalNumberOfErrors</key><integer>3</integer></dict>
        </dict>
      </dict>
    </dict></plist>
    """

    @Test func parsesXcodeManifestEntries() throws {
        let records = XcodeBuilds.records(fromManifest: Data(manifest.utf8)).sorted { $0.started < $1.started }
        #expect(records.count == 2)
        #expect(records[0].name == "Runner · Debug")
        #expect(records[0].status == .success)
        #expect(abs(records[0].duration - 74.63) < 0.01)
        #expect(records[1].name == "Orbit")
        #expect(records[1].status == .failure)
    }

    @Test func projectNameDropsTheDerivedDataHash() {
        #expect(XcodeBuilds.projectName(fromFolder: "Runner-gfwxsigjyqmlldfleqqcnlyplfcp") == "Runner")
        #expect(XcodeBuilds.projectName(fromFolder: "My-App-abcdefghijklmnopqrstuvwxyz") == "My-App")
        #expect(XcodeBuilds.projectName(fromFolder: "DilexaVerify") == "DilexaVerify")
    }

    @Test func findsXcodeJobsByAncestry() {
        let processes = [
            ProcessScanner.Info(pid: 10, parent: 1, name: "Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            ProcessScanner.Info(pid: 11, parent: 10, name: "SWBBuildService", path: "/x/SWBBuildService"),
            ProcessScanner.Info(pid: 12, parent: 11, name: "swift-frontend", path: "/x/swift-frontend"),
            ProcessScanner.Info(pid: 20, parent: 1, name: "swift-frontend", path: "/x/swift-frontend"), // SwiftPM, not Xcode
        ]
        #expect(XcodeBuilds.activeJobs(in: processes).map(\.pid) == [12])
    }

    let gradleLog = """
    2026-09-14T13:13:21.297+0500 [INFO] [org.gradle.launcher.daemon.server.DefaultIncomingConnectionHandler] Received command: Build{id=aaa, currentDir=/Users/me/Projects/Orbit/android, …}.
    2026-09-14T13:13:41.254+0500 [DEBUG] [org.gradle.launcher.daemon.server.exec.ExecuteBuild] The daemon has finished executing the build.
    2026-09-14T14:00:00.000+0500 [INFO] [org.gradle.launcher.daemon.server.DefaultIncomingConnectionHandler] Received command: Build{id=bbb, currentDir=/Users/me/Projects/Orbit/android, …}.
    """

    @Test func scansGradleDaemonLogs() {
        let scan = GradleBuilds.scan(log: gradleLog, file: "daemon-1.out.log", daemonAlive: false)
        #expect(scan.finished.count == 1)
        #expect(scan.finished.first?.name == "Orbit")
        #expect(abs((scan.finished.first?.duration ?? 0) - 19.957) < 0.01)
        #expect(scan.finished.first?.status == .unknown)
        // An unfinished build of a dead daemon is not "running".
        #expect(scan.running == nil)
    }

    @Test func gradleTimestampsWithCompactOffsets() {
        #expect(GradleBuilds.timestamp("2026-09-14T13:13:21.297+0500 [INFO] x") != nil)
        #expect(GradleBuilds.pid(ofLog: URL(fileURLWithPath: "/x/daemon-38773.out.log")) == 38773)
    }

    @Test func clearingRefusesAnyFolderButDerivedData() async throws {
        let elsewhere = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/NotDerivedData-\(UUID().uuidString)")
        #expect(await XcodeBuilds.clear(root: elsewhere) == 0)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("DD-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("Orbit-abc"), withIntermediateDirectories: true)
        #expect(await XcodeBuilds.clear(root: temp) == 1)
        #expect(FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func clockFormat() {
        #expect(BuildFormat.clock(42) == "0:42")
        #expect(BuildFormat.clock(68) == "1:08")
        #expect(BuildFormat.clock(3723) == "1:02:03")
    }
}

@Suite struct ShortcutTests {
    @Test func displaysLikeTheMock() {
        #expect(Shortcut.optionSpace.display == "⌥ Space")
        #expect(Shortcut.clipboard.display == "⇧⌘ V")
    }
}

@Suite struct BuildStatsTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func record(_ id: String, _ scheme: String, endingAt end: Date, seconds: TimeInterval, status: BuildRecord.Status = .success) -> BuildRecord {
        BuildRecord(id: id, name: "\(scheme) · Debug", status: status, started: end.addingTimeInterval(-seconds), finished: end, scheme: scheme)
    }

    @Test func historyMergesByIdAndKeepsNewestFirst() {
        let now = Date()
        var history = BuildHistory()
        let first = history.merge([record("a", "Orbit", endingAt: now.addingTimeInterval(-100), seconds: 10)])
        let again = history.merge([record("a", "Orbit", endingAt: now.addingTimeInterval(-100), seconds: 10)])
        #expect(first)
        #expect(!again)
        history.merge([record("b", "Orbit", endingAt: now, seconds: 5)])
        #expect(history.records.map(\.id) == ["b", "a"])
    }

    @Test func historySurvivesARoundTripToDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID()).json")
        var history = BuildHistory()
        history.merge([record("a", "Orbit", endingAt: Date(), seconds: 42, status: .failure)])
        history.save(to: file)
        let loaded = BuildHistory.load(from: file)
        #expect(loaded.records.first?.status == .failure)
        #expect(loaded.records.first?.scheme == "Orbit")
    }

    @Test func weekSummaryTotalsCountsAndSplitsBySchemes() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12)))
        let records = [
            record("1", "Orbit", endingAt: now.addingTimeInterval(-3600), seconds: 60),
            record("2", "Orbit", endingAt: now.addingTimeInterval(-86400), seconds: 120, status: .failure),
            record("3", "Kit", endingAt: now.addingTimeInterval(-2 * 86400), seconds: 30),
            record("old", "Orbit", endingAt: now.addingTimeInterval(-30 * 86400), seconds: 999),
        ]
        let summary = BuildStats.summary(records, range: .week, now: now, calendar: calendar)
        #expect(summary.builds == 3)
        #expect(summary.total == 210)
        #expect(summary.average == 70)
        #expect(summary.failures == 1)
        #expect(summary.buckets.count == 7)
        #expect(summary.buckets.last?.total == 60)
        #expect(summary.schemes.map(\.name) == ["Orbit", "Kit"])
    }

    @Test func todayIsBrokenIntoHoursAndAllCountsEverything() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12)))
        let records = [
            record("1", "Orbit", endingAt: now.addingTimeInterval(-1800), seconds: 60),
            record("old", "Orbit", endingAt: now.addingTimeInterval(-900 * 86400), seconds: 100),
        ]
        let today = BuildStats.summary(records, range: .today, now: now, calendar: calendar)
        #expect(today.buckets.count == 24)
        #expect(today.buckets[11].total == 60)
        #expect(BuildStats.today(records, now: now, calendar: calendar) == 60)
        let all = BuildStats.summary(records, range: .all, now: now, calendar: calendar)
        #expect(all.total == 160)
        #expect(all.buckets.count == 24)
    }

    @Test func durationsReadLikeTheMenuBar() {
        #expect(BuildStats.duration(35) == "35s")
        #expect(BuildStats.duration(84) == "1m 24s")
        #expect(BuildStats.duration(42 * 60) == "42m")
        #expect(BuildStats.duration(72 * 60) == "1h 12m")
        #expect(BuildStats.duration(12 * 3600 + 300) == "12h")
    }

    @Test func cleanEntriesAreNotBuilds() {
        let manifest = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>logs</key><dict>
        <key>C</key><dict><key>title</key><string>Cleaning workspace Orbit with scheme Orbit</string>
        <key>timeStartedRecording</key><real>1</real><key>timeStoppedRecording</key><real>5</real></dict>
        </dict></dict></plist>
        """
        #expect(XcodeBuilds.records(fromManifest: Data(manifest.utf8)).isEmpty)
    }
}
