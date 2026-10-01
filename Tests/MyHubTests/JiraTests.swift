import Foundation
import Testing
@testable import MyHub

@Suite struct JiraSiteTests {
    @Test func acceptsOnlyAtlassianCloudSites() {
        #expect(JiraSite("acme")?.host == "acme.atlassian.net")
        #expect(JiraSite("https://ACME.atlassian.net/jira/software/projects/ORB")?.host == "acme.atlassian.net")
        #expect(JiraSite(" acme-eu.atlassian.net ")?.host == "acme-eu.atlassian.net")
        #expect(JiraSite("jira.acme.com") == nil)
        #expect(JiraSite("acme.atlassian.net.evil.com") == nil)
        #expect(JiraSite("a.b.atlassian.net") == nil)
        #expect(JiraSite("") == nil)
    }

    @Test func buildsLinksOnTheSiteOnly() throws {
        let site = try #require(JiraSite("acme"))
        #expect(site.browse("ORB-142")?.absoluteString == "https://acme.atlassian.net/browse/ORB-142")
        #expect(site.browse("ORB-142", comment: "10001")?.absoluteString == "https://acme.atlassian.net/browse/ORB-142?focusedCommentId=10001")
        #expect(site.board(7)?.absoluteString == "https://acme.atlassian.net/secure/RapidBoard.jspa?rapidView=7")
        #expect(site.owns(try #require(site.search("assignee = currentUser()"))))
        #expect(!site.owns(URL(string: "https://evil.com/browse/ORB-1")!))
        #expect(!site.owns(URL(string: "http://acme.atlassian.net/browse/ORB-1")!))
    }

    @Test func issueKeysAreValidatedBeforeUse() {
        #expect(JiraClient.isIssueKey("ORB-142"))
        #expect(JiraClient.isIssueKey("A1_B-7"))
        #expect(!JiraClient.isIssueKey("orb-142"))
        #expect(!JiraClient.isIssueKey("ORB-142/../../x"))
        #expect(!JiraClient.isIssueKey("ORB"))
    }
}

@Suite struct JiraDecodingTests {
    @Test func searchResultsMapPriorityAndStatus() throws {
        let json = """
        {"issues":[
          {"key":"ORB-142","fields":{"summary":"Drag-out flicker","priority":{"name":"High"},
            "status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"updated":"2026-10-01T10:15:30.123+0000"}},
          {"key":"ORB-138","fields":{"summary":"Clipboard search","priority":{"name":"Medium"},
            "status":{"name":"Code Review","statusCategory":{"key":"indeterminate"}},"updated":"2026-10-01T11:00:00.000+0000"}},
          {"key":"ORB-129","fields":{"summary":"Gradle stop","priority":{"name":"Lowest"},
            "status":{"name":"Backlog","statusCategory":{"key":"new"}},"updated":"2026-09-30T09:00:00.000+0000"}},
          {"key":"../evil","fields":{"summary":"x"}}
        ]}
        """
        let issues = try JiraDecoding.issues(from: Data(json.utf8))
        #expect(issues.map(\.key) == ["ORB-142", "ORB-138", "ORB-129"])
        #expect(issues[0].priority == .high && issues[0].status == .inProgress)
        #expect(issues[1].status == .inReview)
        #expect(issues[2].priority == .low && issues[2].status == .todo)
        #expect(issues[0].updated == ISODate.parse("2026-10-01T10:15:30.123Z"))
    }

    @Test func ordersByPriorityThenRecency() {
        let now = Date()
        let issues = [
            JiraIssue(key: "A-1", summary: "", priority: .low, status: .todo, updated: now),
            JiraIssue(key: "A-2", summary: "", priority: .high, status: .todo, updated: now.addingTimeInterval(-100)),
            JiraIssue(key: "A-3", summary: "", priority: .high, status: .todo, updated: now),
        ]
        #expect(JiraIssue.ordered(issues).map(\.key) == ["A-3", "A-2", "A-1"])
    }

    @Test func findsMentionsInADFComments() throws {
        let json = """
        {"comments":[
          {"id":"1","author":{"accountId":"ana","displayName":"Ana Kovač"},"created":"2026-10-01T10:00:00.000+0000",
           "body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[
             {"type":"mention","attrs":{"id":"me","text":"@Oraz"}},{"type":"text","text":" can you check   this on the Studio Display?"}]}]}},
          {"id":"2","author":{"accountId":"ana","displayName":"Ana Kovač"},"created":"2026-10-01T10:05:00.000+0000",
           "body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"No mention here"}]}]}},
          {"id":"3","author":{"accountId":"me","displayName":"Oraz"},"created":"2026-10-01T10:06:00.000+0000",
           "body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"mention","attrs":{"id":"me"}}]}]}},
          {"id":"4","author":{"accountId":"marco","displayName":"Marco Ruiz"},"created":"2026-09-01T10:00:00.000+0000",
           "body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"mention","attrs":{"id":"me"}}]}]}}
        ]}
        """
        let issue = JiraIssue(key: "ORB-142", summary: "Drag-out flicker", priority: .high, status: .inProgress, updated: Date())
        let since = try #require(ISODate.parse("2026-09-24T00:00:00Z"))
        let mentions = try JiraDecoding.mentions(from: Data(json.utf8), issue: issue, accountID: "me", since: since)
        #expect(mentions.map(\.id) == ["1"])
        #expect(mentions[0].body == "@Oraz can you check this on the Studio Display?")
        #expect(mentions[0].initials == "AK")
        #expect(mentions[0].issueSummary == "Drag-out flicker")
    }

    @Test func sprintColumnsCountAllAndListMine() throws {
        let json = """
        {"issues":[
          {"key":"ORB-151","fields":{"status":{"name":"To Do","statusCategory":{"key":"new"}},"assignee":{"accountId":"me"}}},
          {"key":"ORB-160","fields":{"status":{"name":"To Do","statusCategory":{"key":"new"}},"assignee":{"accountId":"ana"}}},
          {"key":"ORB-142","fields":{"status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"assignee":{"accountId":"me"}}},
          {"key":"ORB-138","fields":{"status":{"name":"In Review","statusCategory":{"key":"indeterminate"}},"assignee":null}},
          {"key":"ORB-117","fields":{"status":{"name":"Done","statusCategory":{"key":"done"}},"assignee":{"accountId":"me"}}}
        ]}
        """
        let columns = try JiraDecoding.sprintColumns(from: Data(json.utf8), accountID: "me")
        #expect(columns.counts == [.todo: 2, .inProgress: 1, .inReview: 1, .done: 1])
        #expect(columns.mine[.todo] == ["ORB-151"])
        #expect(columns.mine[.inReview] == nil)
        #expect(columns.mine[.done] == ["ORB-117"])
    }

    @Test func boardsSprintsAndMyself() throws {
        let boards = try JiraDecoding.boards(from: Data(#"{"values":[{"id":3,"name":"ORB board","type":"scrum"},{"id":4,"name":"Ops","type":"kanban"}]}"#.utf8))
        #expect(boards.map(\.scrum) == [true, false])
        let sprint = try #require(try JiraDecoding.activeSprint(from: Data(
            #"{"values":[{"id":24,"name":"Sprint 24","startDate":"2026-09-23T08:00:00.000Z","endDate":"2026-10-06T08:00:00.000Z"}]}"#.utf8)))
        #expect(sprint.id == 24 && sprint.end != nil)
        #expect(try JiraDecoding.activeSprint(from: Data(#"{"values":[]}"#.utf8)) == nil)
        let me = try JiraDecoding.account(from: Data(#"{"accountId":"5b10a","displayName":"Oraz","emailAddress":"x"}"#.utf8))
        #expect(me == JiraAccount(id: "5b10a", name: "Oraz"))
    }

    @Test func repliesBecomeADFParagraphs() throws {
        let doc = ADFNode.document("First\n\nSecond")
        let data = try JSONSerialization.data(withJSONObject: doc)
        let node = try JSONDecoder().decode(ADFNode.self, from: data)
        #expect(node.type == "doc")
        #expect(node.content?.count == 2)
        #expect(node.plainText == "First Second")
    }

    @Test func daysLeftCountsCalendarDays() {
        let now = Date()
        let sprint = JiraSprint(id: 1, boardID: 1, name: "S", start: now, end: now.addingTimeInterval(4 * 86400),
                                counts: [.done: 18, .todo: 13], mine: [:])
        #expect(sprint.daysLeft(now: now) == 4)
        #expect(sprint.total == 31)
    }
}
