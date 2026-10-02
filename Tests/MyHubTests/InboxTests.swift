import Foundation
import Testing
@testable import MyHub

@Suite struct InboxDecodingTests {
    let pull = GitHubInboxDecoding.Hit(id: 9, number: 128, title: "Sign in with Apple",
                                       url: URL(string: "https://github.com/orbit-labs/orbit/pull/128")!,
                                       repo: GitHubRepo(remote: "https://github.com/orbit-labs/orbit")!, author: "robin-v",
                                       updated: Date(), isPullRequest: true)
    let since = ISODate.parse("2026-09-24T00:00:00Z")!

    @Test func searchHitsKnowTheirRepoAndRefuseForeignLinks() throws {
        let json = """
        {"total_count":2,"items":[
          {"id":1,"number":128,"title":"Sign in with Apple","html_url":"https://github.com/orbit-labs/orbit/pull/128",
           "repository_url":"https://api.github.com/repos/orbit-labs/orbit","updated_at":"2026-10-01T10:00:00Z",
           "user":{"login":"ana"},"pull_request":{"url":"x"}},
          {"id":2,"number":5,"title":"Evil","html_url":"https://evil.example/5",
           "repository_url":"https://api.github.com/repos/a/b","updated_at":"2026-10-01T10:00:00Z","user":{"login":"x"}}
        ]}
        """
        let hits = try GitHubInboxDecoding.hits(from: Data(json.utf8))
        #expect(hits.count == 1)
        #expect(hits[0].reference == "orbit-labs/orbit #128")
        #expect(hits[0].isPullRequest)
        #expect(GitHubInboxDecoding.repo(fromAPI: "https://api.example.com/repos/a/b") == nil)
    }

    @Test func reviewsByOthersOnlyWithTheirVerdict() throws {
        let json = """
        [{"id":1,"user":{"login":"ana"},"state":"APPROVED","body":"LGTM","submitted_at":"2026-10-01T09:00:00Z",
          "html_url":"https://github.com/orbit-labs/orbit/pull/128#pullrequestreview-1"},
         {"id":2,"user":{"login":"marco"},"state":"CHANGES_REQUESTED","body":"> quoted\\nPlease rename this.","submitted_at":"2026-10-01T09:30:00Z",
          "html_url":"https://github.com/orbit-labs/orbit/pull/128#pullrequestreview-2"},
         {"id":3,"user":{"login":"Robin-V"},"state":"COMMENTED","body":"self","submitted_at":"2026-10-01T09:40:00Z",
          "html_url":"https://github.com/orbit-labs/orbit/pull/128#pullrequestreview-3"},
         {"id":4,"user":{"login":"ana"},"state":"PENDING","body":"","submitted_at":"2026-10-01T09:50:00Z",
          "html_url":"https://github.com/orbit-labs/orbit/pull/128#pullrequestreview-4"},
         {"id":5,"user":{"login":"ana"},"state":"APPROVED","body":"old","submitted_at":"2026-09-01T09:00:00Z",
          "html_url":"https://github.com/orbit-labs/orbit/pull/128#pullrequestreview-5"}]
        """
        let items = try GitHubInboxDecoding.reviews(from: Data(json.utf8), on: pull, me: "robin-v", since: since)
        #expect(items.map(\.kind) == [.approved, .changesRequested])
        #expect(items[1].snippet == "Please rename this.")
        #expect(items[0].id == "gh-review-1")
    }

    @Test func commentsSkipMyOwnAndBots() throws {
        let json = """
        [{"id":11,"user":{"login":"ana"},"body":"Can you add a test?","created_at":"2026-10-01T09:00:00Z",
          "html_url":"https://github.com/orbit-labs/orbit/pull/128#issuecomment-11"},
         {"id":12,"user":{"login":"dependabot[bot]"},"body":"Bump","created_at":"2026-10-01T09:00:00Z",
          "html_url":"https://github.com/orbit-labs/orbit/pull/128#issuecomment-12"},
         {"id":13,"user":{"login":"robin-v"},"body":"Done","created_at":"2026-10-01T09:00:00Z",
          "html_url":"https://github.com/orbit-labs/orbit/pull/128#issuecomment-13"}]
        """
        let items = try GitHubInboxDecoding.comments(from: Data(json.utf8), on: pull, me: "robin-v", since: since)
        #expect(items.map(\.actor) == ["ana"])
        #expect(items[0].kind == .commented)
    }

    @Test func snippetsAreOneReadableLine() {
        #expect(GitHubInboxDecoding.snippet("> quote\n```swift\nlet x = 1\n```\n  Looks   good\n\nThanks") == "let x = 1 Looks good Thanks")
        #expect(GitHubInboxDecoding.snippet(nil) == "")
        #expect(GitHubInboxDecoding.snippet(String(repeating: "a", count: 500)).count == 200)
    }

    @Test func mergeIsNewestFirstWithoutDuplicates() {
        let url = URL(string: "https://github.com/a/b/pull/1")!
        func item(_ id: String, _ ago: TimeInterval) -> InboxItem {
            InboxItem(id: id, source: .github, kind: .commented, title: id, reference: "a/b #1", actor: "x",
                      snippet: "", date: Date().addingTimeInterval(-ago), url: url)
        }
        let merged = InboxItem.merged([[item("a", 60), item("b", 10)], [item("a", 60), item("c", 30)]])
        #expect(merged.map(\.id) == ["b", "c", "a"])
    }
}

@Suite struct TaggedTitleTests {
    @Test func conventionalCommitPrefixesBecomeChips() {
        let t = TaggedTitle("feat(stash): Keep drag order when files are renamed")
        #expect(t.tag == .change(type: "feat", scope: "stash"))
        #expect(t.text == "Keep drag order when files are renamed")
        #expect(TaggedTitle("fix!: Crash on launch").tag == .change(type: "fix", scope: nil))
        #expect(TaggedTitle("Note: this is not a type").tag == nil)
    }

    @Test func ticketKeysBecomeChips() {
        #expect(TaggedTitle("ORB-412 Calendar day view") == TaggedTitle("[ORB-412] Calendar day view"))
        #expect(TaggedTitle("ORB-412: Calendar day view").tag == .ticket("ORB-412"))
        #expect(TaggedTitle("ORB-412: Calendar day view").text == "Calendar day view")
        #expect(TaggedTitle("Add dark mode to the onboarding flow").tag == nil)
    }

    @Test func itemsKnowTheirSectionAndShortReference() {
        let item = InboxItem(id: "x", source: .github, kind: .approved, title: "t", reference: "orbit-labs/orbit #128",
                             actor: "ana", snippet: "", date: Date(), url: URL(string: "https://github.com/orbit-labs/orbit/pull/128")!)
        #expect(item.group == .reviewsOnYours)
        #expect(item.shortReference == "orbit #128")
    }
}

@Suite struct TabKeyTests {
    @Test func everyTabHasItsOwnKey() {
        let keys = Section.allCases.map(\.switchKey)
        #expect(Set(keys.map(\.label)).count == Section.allCases.count)
        #expect(Set(keys.map(\.keyCode)).count == Section.allCases.count)
        #expect(Section.settings.switchKey.label == ",")
    }
}

@MainActor
@Suite struct FormDraftsTests {
    @Test func draftsSurviveTheViewAndClearOnSubmit() {
        let drafts = FormDrafts()
        drafts.binding("jira.site").wrappedValue = "acme"
        drafts["jira.token"] = "secret"
        #expect(drafts["jira.site"] == "acme")
        drafts.seed("jira.site", "other")          // typed text wins over the saved value
        #expect(drafts["jira.site"] == "acme")
        drafts.seed("jira.email", "me@acme.com")
        #expect(drafts["jira.email"] == "me@acme.com")
        drafts.clear("jira.token")
        #expect(drafts["jira.token"].isEmpty)
        drafts.flag("open").wrappedValue = true
        #expect(drafts.flag("open").wrappedValue)
    }
}

@Suite struct BuildBucketDetailTests {
    @Test func bucketsCountFailuresAndCarryAFullTitle() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func record(_ ago: TimeInterval, _ status: BuildRecord.Status) -> BuildRecord {
            BuildRecord(id: UUID().uuidString, name: "Orbit", status: status,
                        started: now.addingTimeInterval(-ago - 60), finished: now.addingTimeInterval(-ago))
        }
        let summary = BuildStats.summary([record(100, .success), record(200, .failure)], range: .week, now: now, calendar: calendar)
        let last = summary.buckets.last!
        #expect(last.builds == 2)
        #expect(last.failures == 1)
        #expect(!last.title.isEmpty && last.title != last.label)
    }
}

@MainActor
@Suite struct BuildSchemeFilterTests {
    @Test func hiddenSchemesLeaveTheTotalsButStayInTheLegend() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubBuilds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefs = Preferences(file: folder.appendingPathComponent("prefs.json"))
        let store = BuildStore(preferences: prefs, historyFile: folder.appendingPathComponent("history.json"))
        let now = Date()
        func record(_ scheme: String, _ ago: TimeInterval) -> BuildRecord {
            BuildRecord(id: UUID().uuidString, name: scheme, status: .success,
                        started: now.addingTimeInterval(-ago - 60), finished: now.addingTimeInterval(-ago))
        }
        store.injectHistoryForPreview([record("Orbit", 100), record("Orbit", 200), record("Widgets", 300)])
        #expect(store.summary(now: now).builds == 3)
        store.toggleScheme("Widgets")
        #expect(store.isSchemeHidden("Widgets"))
        #expect(store.summary(now: now).builds == 2)
        #expect(store.schemesInRange(now: now).map(\.name).sorted() == ["Orbit", "Widgets"])
        #expect(Preferences(file: folder.appendingPathComponent("prefs.json")).values.builds.hiddenSchemes == ["Widgets"])
        store.showAllSchemes()
        #expect(store.summary(now: now).builds == 3)
    }
}

@MainActor
@Suite struct TabSteppingTests {
    @Test func arrowsWrapAroundAndSkipHiddenTabs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubTabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefs = Preferences(file: folder.appendingPathComponent("prefs.json"))
        let model = HubModel(preferences: prefs, stash: StashStore(file: folder.appendingPathComponent("stash.json"), rendersPreviews: false),
                             notesFile: folder.appendingPathComponent("notes.json"),
                             buildHistoryFile: folder.appendingPathComponent("builds.json"))
        let coordinator = IslandCoordinator(model: model)
        model.section = .stash
        coordinator.stepTab(by: -1)
        #expect(model.section == .settings)          // wraps from the first to the last
        coordinator.stepTab(by: 1)
        #expect(model.section == .stash)
        model.setVisible(.inbox, false)
        coordinator.stepTab(by: 1)
        #expect(model.section == .agents)            // hidden Inbox is skipped
    }
}

@Suite struct ProcessScannerTests {
    @Test func theFastScanNamesProcessesLikeTheirExecutable() throws {
        let me = getpid()
        let fast = try #require(ProcessScanner.all().first { $0.pid == me })
        let full = try #require(ProcessScanner.info(me))
        #expect(fast.parent == full.parent)
        #expect(!fast.name.isEmpty)
        #expect(full.name.hasPrefix(fast.name) || fast.name.hasPrefix(full.name))
    }
}
