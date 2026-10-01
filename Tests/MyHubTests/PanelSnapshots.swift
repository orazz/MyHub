import AppKit
import SwiftUI
import Testing
@testable import MyHub

/// Opt-in visual check: `MYHUB_SNAPSHOT_DIR=/path swift test --filter PanelSnapshots`
/// renders each tab inside the real panel chrome, with sample data, to PNGs.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MYHUB_SNAPSHOT_DIR"] != nil))
struct PanelSnapshots {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MYHUB_SNAPSHOT_DIR"] ?? "/tmp")
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubSnap-\(UUID().uuidString)")

    func makeModel() throws -> (HubModel, ([Meeting], Date)) {
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let prefs = Preferences(file: temp.appendingPathComponent("prefs.json"))
        let stash = StashStore(file: temp.appendingPathComponent("stash.json"), rendersPreviews: false)
        var files: [URL] = []
        for (name, size) in [("hero-shot@2x.png", 2_400_000), ("Invoice-0921.pdf", 184_000), ("Orbit-build-42.zip", 5_600_000)] {
            let url = temp.appendingPathComponent(name)
            try Data(count: size).write(to: url)
            files.append(url)
        }
        stash.add(files.reversed())
        let model = HubModel(preferences: prefs, stash: stash, notesFile: temp.appendingPathComponent("notes.json"),
                             buildHistoryFile: temp.appendingPathComponent("build-history.json"))
        let now = Date()
        model.clipboard.injectForPreview([
            ("https://developer.apple.com/documentation/swiftui/", "Safari", 10),
            ("rm -rf ~/Library/Developer/Xcode/DerivedData", "Terminal", 240),
            ("Ship the notch build Friday, QA on Thursday", "Slack", 720),
            ("#E8A94A", "Figma", 3600),
        ], now: now)
        model.notes.add()
        model.notes.update(model.notes.selectedID!, text: "Notch build checklist\n- [x] Bump version to 1.4\n- [x] Test on external display\n- [ ] Check drag-out animation\n- [ ] Notarize and upload")
        model.usage.add(.claudePlan)
        model.usage.add(.claudeLogs)
        let plan = model.usage.accounts[0].id, logs = model.usage.accounts[1].id
        model.usage.inject(UsageSnapshot(accountID: plan, kind: .claudePlan, planLabel: "Max plan", windows: [
            QuotaWindow(id: "five_hour", label: "5-hour", used: 0.62, resetsAt: now.addingTimeInterval(6480)),
            QuotaWindow(id: "seven_day", label: "Weekly", used: 0.34, resetsAt: now.addingTimeInterval(4 * 86400)),
        ], fidelity: .unofficial, fetchedAt: now))
        let tokens = [400, 650, 300, 800, 550, 450, 950].enumerated().map { (now.addingTimeInterval(Double($0.offset - 6) * 86400), $0.element * 1300) }
        model.usage.inject(UsageSnapshot(accountID: logs, kind: .claudeLogs, daily: DailySeries.build(tokens, now: now), fidelity: .estimated, fetchedAt: now))

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func at(_ day: Date, _ hour: Int, _ minute: Int) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)! }
        let workday = AgendaFormat.nextWorkday(after: now)
        let green = RGBA(NSColor(srgbRed: 0.44, green: 0.81, blue: 0.56, alpha: 1)), blue = RGBA(NSColor(srgbRed: 0.49, green: 0.71, blue: 0.95, alpha: 1))
        let soon = now.addingTimeInterval(20 * 60)
        // Injected after switching to the tab: opening Calendar re-checks the
        // real permission, which would replace the preview.
        let previewMeetings: ([Meeting], Date) = ([
            Meeting(id: "1", title: "Design review", start: soon, end: soon.addingTimeInterval(3600), color: blue, calendarTitle: "Work",
                    link: URL(string: "https://meet.google.com/abc-defg-hij"), provider: "Google Meet", attendees: 4),
            Meeting(id: "2", title: "Release notes pass", start: soon.addingTimeInterval(2700), end: soon.addingTimeInterval(4500), color: green,
                    calendarTitle: "Work", link: nil, provider: nil),
            Meeting(id: "3", title: "Standup", start: at(workday, 9, 0), end: at(workday, 9, 15), color: blue, calendarTitle: "Work", link: nil, provider: nil),
            Meeting(id: "4", title: "QA handoff", start: at(workday, 14, 0), end: at(workday, 15, 0), color: blue, calendarTitle: "Work", link: nil, provider: nil),
        ].filter { $0.start > today }, now)
        return (model, previewMeetings)
    }

    @Test func renderEveryTab() async throws {
        let (model, meetings) = try makeModel()
        // A week of synthetic builds across three schemes, for the Stats view.
        let now = Date()
        var records: [BuildRecord] = []
        for day in 0..<7 {
            for (index, scheme) in ["Orbit", "OrbitKit", "Widgets"].enumerated() where (day + index) % 3 != 2 {
                for build in 0..<(2 + (day * 3 + index) % 4) {
                    let end = now.addingTimeInterval(-Double(day) * 86400 - Double(build * 3600 + index * 600 + 300))
                    let length = Double(40 + (day * 17 + index * 23 + build * 11) % 90)
                    records.append(BuildRecord(id: "\(day)-\(scheme)-\(build)", name: "\(scheme) · Debug",
                                               status: build == 1 && day == 2 ? .failure : .success,
                                               started: end.addingTimeInterval(-length), finished: end, scheme: scheme))
                }
            }
        }
        model.builds.injectHistoryForPreview(records)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let screen = NSScreen.screens.first, let metrics = ScreenMetrics(screen: screen, fullHeightDrawn: false,
                                                                           panelSize: PanelSize(rawValue: ProcessInfo.processInfo.environment["MYHUB_SNAPSHOT_SIZE"] ?? "") ?? .standard,
                                                                           position: PanelPosition(rawValue: ProcessInfo.processInfo.environment["MYHUB_SNAPSHOT_POSITION"] ?? "") ?? .center) else { return }
        let session = ScreenSession(metrics: metrics, model: model)
        session.isOpen = true
        // The closed island first.
        session.isOpen = false
        try await render(model: model, session: session, metrics: metrics, name: "closed")
        session.isOpen = true
        // Frames of the open animation: the shape mid-growth must reveal the
        // content inside it, never show content outside the black.
        model.section = .stash
        let from = metrics.collapsedSize, to = metrics.bodySize
        for t in [0.25, 0.55, 0.85] {
            session.debugBodySize = CGSize(width: from.width + (to.width - from.width) * t, height: from.height + (to.height - from.height) * t)
            try await render(model: model, session: session, metrics: metrics, name: "opening-\(Int(t * 100))")
        }
        session.debugBodySize = nil
        for section in Section.allCases {
            model.section = section
            if section == .calendar {
                model.agenda.injectForPreview(meetings.0, now: meetings.1)
                let teams = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0")!
                let base = meetings.1
                model.agenda.microsoft.injectForPreview([
                    Meeting(id: "ms-1", title: "Sprint planning", start: base.addingTimeInterval(20 * 60), end: base.addingTimeInterval(80 * 60),
                            color: MicrosoftCalendar.color, calendarTitle: "Microsoft 365", link: teams, provider: "Teams", attendees: 8),
                    Meeting(id: "ms-2", title: "1:1 with Ana", start: base.addingTimeInterval(5 * 3600), end: base.addingTimeInterval(5.5 * 3600),
                            color: MicrosoftCalendar.color, calendarTitle: "Microsoft 365", link: teams, provider: "Teams", attendees: 2),
                ], account: "Oraz · oraz@example.com")
            }
            if section == .builds { model.builds.mode = .stats }
            try await render(model: model, session: session, metrics: metrics, name: section.rawValue)
            if section == .builds {
                model.builds.previewHoverIndex = 5
                try await render(model: model, session: session, metrics: metrics, name: "builds-hover")
                model.builds.previewHoverIndex = nil
                model.builds.toggleScheme("Widgets")
                try await render(model: model, session: session, metrics: metrics, name: "builds-hidden-scheme")
                model.builds.showAllSchemes()
            }
        }
        try await renderNewTabs(model: model, session: session, metrics: metrics, now: now)
        try await renderJira(model: model, session: session, metrics: metrics, now: now)
        try await renderInbox(model: model, session: session, metrics: metrics, now: now)
        // Every theme, on a busy tab and on the settings that pick it.
        for theme in PanelTheme.allCases {
            ThemeState.shared.theme = theme
            model.jira.view = .assigned
            model.section = .jira
            try await render(model: model, session: session, metrics: metrics, name: "theme-\(theme.rawValue)")
            model.section = .builds
            try await render(model: model, session: session, metrics: metrics, name: "theme-\(theme.rawValue)-builds")
        }
        ThemeState.shared.theme = .aurora
        model.section = .settings
        try await render(model: model, session: session, metrics: metrics, name: "theme-settings")
        ThemeState.shared.theme = .classic
    }

    func renderInbox(model: HubModel, session: ScreenSession, metrics: ScreenMetrics, now: Date) async throws {
        let pr = URL(string: "https://github.com/orazz/orbit/pull/128")!
        model.jira.injectForPreview(connection: .connected, account: JiraAccount(id: "me", name: "Oraz"), assigned: [], mentions: [
            JiraMention(id: "c9", issueKey: "ORB-142", issueSummary: "Drag-out flicker on external displays", author: "Ana Kovač",
                        authorID: "ana", body: "@Oraz can you check if this repros on the Studio Display too?", created: now.addingTimeInterval(-1500)),
        ], sprint: nil)
        func gh(_ id: String, _ kind: InboxItem.Kind, _ title: String, _ ref: String, _ who: String, _ ago: TimeInterval,
                _ snippet: String = "") -> InboxItem {
            InboxItem(id: id, source: .github, kind: kind, title: title, reference: ref, actor: who, snippet: snippet,
                      date: now.addingTimeInterval(-ago), url: pr)
        }
        model.inbox.injectForPreview([
            gh("gh-request-1", .reviewRequested, "feat(sync-api): Make the widget refresh payload optional",
               "orbit-labs/graph-schema #338", "maya-k", 57 * 60),
            gh("gh-request-2", .reviewRequested, "Route ticket lookups through the parser",
               "orbit-labs/team-skills #29", "jdoe", 14 * 3600),
            gh("gh-request-3", .reviewRequested, "ORB-412 Upgrade sheet", "orbit-labs/orbit-ios #1518", "sam-r", 17 * 3600),
            gh("gh-request-4", .reviewRequested, "Add analytics event table", "orbit-labs/team-skills #28", "lee-park", 18 * 3600),
            gh("gh-review-5", .changesRequested, "fix(auth): Move nonce handling into the auth service", "orazz/orbit #128", "ana",
               3 * 3600, "Please keep the nonce out of the view model."),
        ])
        model.inbox.markRead([gh("gh-request-3", .reviewRequested, "", "", "", 0), gh("gh-request-4", .reviewRequested, "", "", "", 0)])
        model.section = .inbox
        try await render(model: model, session: session, metrics: metrics, name: "inbox")
        model.showsTabKeys = true
        try await render(model: model, session: session, metrics: metrics, name: "inbox-tab-keys")
        model.showsTabKeys = false
        session.isOpen = false
        try await render(model: model, session: session, metrics: metrics, name: "closed-badge")
        session.isOpen = true
    }

    /// The nine states of the Jira handoff.
    func renderJira(model: HubModel, session: ScreenSession, metrics: ScreenMetrics, now: Date) async throws {
        let jira = model.jira
        let me = JiraAccount(id: "me", name: "Oraz")
        let issues = [
            JiraIssue(key: "ORB-142", summary: "Drag-out flicker on external displays", priority: .high, status: .inProgress, updated: now),
            JiraIssue(key: "ORB-138", summary: "Clipboard search ignores pinned items", priority: .medium, status: .inReview, updated: now),
            JiraIssue(key: "ORB-151", summary: "Build badge timer drifts after sleep", priority: .medium, status: .todo, updated: now),
            JiraIssue(key: "ORB-129", summary: "Add Gradle daemon stop action", priority: .low, status: .todo, updated: now),
            JiraIssue(key: "ORB-117", summary: "Settings: reorder dock tabs", priority: .low, status: .done, updated: now),
        ]
        let mentions = [
            JiraMention(id: "c1", issueKey: "ORB-142", issueSummary: "Drag-out flicker", author: "Ana Kovač", authorID: "ana",
                        body: "@you can you check if this repros on the Studio Display too? I only see it on the LG.", created: now.addingTimeInterval(-480)),
            JiraMention(id: "c2", issueKey: "ORB-138", issueSummary: "Clipboard search", author: "Marco Ruiz", authorID: "marco",
                        body: "@you pushed a fix, moving to review. Pinned items now match on title and content.", created: now.addingTimeInterval(-3600)),
        ]
        let sprint = JiraSprint(id: 24, boardID: 3, name: "Sprint 24 · Notch 1.4", start: now.addingTimeInterval(-9 * 86400),
                                end: now.addingTimeInterval(4 * 86400), counts: [.todo: 9, .inProgress: 4, .inReview: 5, .done: 13],
                                mine: [.todo: ["ORB-151", "ORB-129"], .inProgress: ["ORB-142"], .inReview: ["ORB-138"], .done: ["ORB-117"]])
        model.section = .jira
        func shot(_ name: String, _ connection: JiraStore.Connection, _ view: JiraStore.View,
                  assigned: [JiraIssue] = [], mentions: [JiraMention] = [], sprint: JiraSprint? = nil, form: Bool = false) async throws {
            jira.injectForPreview(connection: connection, account: me, assigned: assigned, mentions: mentions, sprint: sprint)
            jira.view = view
            jira.setupVisible = form
            try await render(model: model, session: session, metrics: metrics, name: "jira-\(name)")
        }
        try await shot("1-disconnected", .disconnected, .assigned)
        try await shot("1b-form", .disconnected, .assigned, form: true)
        try await shot("2-connecting", .connecting, .assigned)
        try await shot("3-expired", .expired, .assigned)
        try await shot("4-assigned", .connected, .assigned, assigned: issues, mentions: mentions, sprint: sprint)
        try await shot("5-mentions", .connected, .mentions, assigned: issues, mentions: mentions, sprint: sprint)
        try await shot("6-sprint", .connected, .sprint, assigned: issues, mentions: mentions, sprint: sprint)
        try await shot("7-empty-assigned", .connected, .assigned)
        try await shot("8-empty-mentions", .connected, .mentions)
        try await shot("9-no-sprint", .connected, .sprint, assigned: issues)
    }

    func renderNewTabs(model: HubModel, session: ScreenSession, metrics: ScreenMetrics, now: Date) async throws {
        let dev = model.dev
        dev.frozen = true
        dev.simulators.injectForPreview([
            SimDevice(udid: "33333333-3333-3333-3333-333333333333", name: "iPhone 16 Pro", runtime: "iOS 18.2", isBooted: true),
            SimDevice(udid: "55555555-5555-5555-5555-555555555555", name: "iPad Air 13-inch", runtime: "iOS 18.2", isBooted: true),
        ])
        let repo = GitHubRepo(remote: "https://github.com/orazz/orbit")!
        var status = GitStatus(); status.branch = "feature/login"; status.ahead = 2; status.changed = 3
        var clean = GitStatus(); clean.branch = "main"
        dev.repos.injectForPreview([
            RepoStore.Repo(path: "/Users/me/Code/orbit", status: status, lastCommit: "Fix keychain race · 2 hours ago", github: repo,
                           pull: PullRequestInfo(number: 128, title: "Sign in with Apple", url: URL(string: "https://github.com/orazz/orbit/pull/128")!,
                                                 draft: false, checks: .pending)),
            RepoStore.Repo(path: "/Users/me/Code/website", status: clean, lastCommit: "Update pricing page · yesterday", github: nil),
        ], runs: [
            WorkflowRun(id: 1, repo: repo, workflow: "CI", title: "Sign in with Apple", branch: "feature/login", event: "push",
                        state: .pending, url: URL(string: "https://github.com/orazz/orbit/actions/runs/1")!,
                        started: now.addingTimeInterval(-185), updated: now),
            WorkflowRun(id: 2, repo: repo, workflow: "Release", title: "v2.4.0", branch: "main", event: "push",
                        state: .success, url: URL(string: "https://github.com/orazz/orbit/actions/runs/2")!,
                        started: now.addingTimeInterval(-7200), updated: now.addingTimeInterval(-6700)),
            WorkflowRun(id: 3, repo: repo, workflow: "CI", title: "Bump dependencies", branch: "deps", event: "pull_request",
                        state: .failure, url: URL(string: "https://github.com/orazz/orbit/actions/runs/3")!,
                        started: now.addingTimeInterval(-86400), updated: now.addingTimeInterval(-86000)),
        ])
        dev.cleanup.injectForPreview(["derived": 14_200_000_000, "devicesupport": 6_100_000_000, "simdevices": 22_400_000_000,
                                      "simcaches": 2_300_000_000, "previews": 900_000_000, "xcodecache": 1_100_000_000,
                                      "swiftpm": 450_000_000, "archives": 3_800_000_000])
        model.section = .dev
        for page in DevHub.Page.allCases {
            dev.page = page
            try await render(model: model, session: session, metrics: metrics, name: "dev-\(page.rawValue)")
        }

        var cycle = FocusCycle()
        cycle.start(at: now.addingTimeInterval(-600), lengths: model.focus.lengths)
        model.focus.injectForPreview(cycle)
        model.section = .focus
        try await render(model: model, session: session, metrics: metrics, name: "focus")
        model.focus.showingSettings = true
        try await render(model: model, session: session, metrics: metrics, name: "focus-settings")
        model.focus.showingSettings = false
        var ready = FocusCycle()
        ready.select(.work)
        model.focus.injectForPreview(ready)
        try await render(model: model, session: session, metrics: metrics, name: "focus-ready")
        model.focus.injectForPreview(cycle)
        session.isOpen = false
        try await render(model: model, session: session, metrics: metrics, name: "closed-focus")
        session.isOpen = true
        model.focus.injectForPreview(FocusCycle())

        model.snippets.add()
        model.snippets.update(model.snippets.selectedID!, title: "Bug report reply",
                              body: "Thanks for the report! I've reproduced it on {{date}} and a fix is on the way.\n\n— Oraz")
        model.notesMode = .snippets
        model.section = .notes
        try await render(model: model, session: session, metrics: metrics, name: "snippets")
        model.notesMode = .notes
    }

    func render(model: HubModel, session: ScreenSession, metrics: ScreenMetrics, name: String) async throws {
        let root = IslandRootView(model: model, session: session)
            .frame(width: metrics.windowSize.width, height: metrics.windowSize.height)
            .background(Color(white: 0.55))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: metrics.windowSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
