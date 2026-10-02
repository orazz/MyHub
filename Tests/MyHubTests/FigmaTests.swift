import Foundation
import Testing
@testable import MyHub

@Suite struct FigmaLinkTests {
    @Test func readsKeysAndNodesFromPastedLinks() throws {
        let link = try #require(FigmaLink("https://www.figma.com/design/AbC123xyZ456qwe/Orbit-Checkout?node-id=12-345&t=x"))
        #expect(link.key == "AbC123xyZ456qwe")
        #expect(link.nodeID == "12:345")
        #expect(FigmaLink("figma.com/file/AbC123xyZ456qwe")?.key == "AbC123xyZ456qwe")
        #expect(FigmaLink("https://www.figma.com/design/AbC123xyZ456qwe/branch/BrAnCh987654zz/Orbit")?.key == "BrAnCh987654zz")
    }

    @Test func refusesAnythingElse() {
        #expect(FigmaLink("https://evil.example.com/design/AbC123xyZ456qwe") == nil)
        #expect(FigmaLink("http://www.figma.com/design/AbC123xyZ456qwe") == nil)
        #expect(FigmaLink("https://www.figma.com/design/../etc/passwd") == nil)
        #expect(FigmaLink("https://www.figma.com/community/file/123") == nil)
        #expect(FigmaLink("https://www.figma.com/design/AbC123xyZ456qwe?node-id=1-2;rm")?.nodeID == nil)
    }

    @Test func buildsLinksToAThread() throws {
        let url = try #require(FigmaLink.web(key: "AbC123xyZ456qwe", node: "12:345", comment: "998877"))
        #expect(url.absoluteString == "https://www.figma.com/design/AbC123xyZ456qwe?node-id=12-345#998877")
        #expect(FigmaLink.isSafeWebURL(url))
        #expect(FigmaLink.web(key: "../x") == nil)
        #expect(!FigmaLink.isSafeWebURL(URL(string: "https://figma.com.example.com/design/x")!))
    }
}

@Suite struct FigmaInboxTests {
    let me = FigmaUser(id: "100", handle: "Robin Vale")
    let now = ISODate.parse("2026-10-02T12:00:00Z")!
    var since: Date { now.addingTimeInterval(-7 * 86400) }

    let commentsJSON = """
    {"comments":[
      {"id":"1","file_key":"AbC123xyZ456qwe","parent_id":"","user":{"id":"100","handle":"Robin Vale","img_url":""},
       "created_at":"2026-10-01T09:00:00Z","resolved_at":null,"message":"Spacing on the header?","order_id":"1",
       "client_meta":{"node_id":"12:345","node_offset":{"x":1,"y":2}},"reactions":[]},
      {"id":"2","file_key":"AbC123xyZ456qwe","parent_id":"1","user":{"id":"200","handle":"Kai Moss","img_url":""},
       "created_at":"2026-10-01T10:00:00Z","resolved_at":null,"message":"Fixed, take a look","order_id":null,
       "client_meta":{"x":10,"y":20},"reactions":[]},
      {"id":"3","file_key":"AbC123xyZ456qwe","parent_id":"","user":{"id":"300","handle":"Ines Park","img_url":""},
       "created_at":"2026-10-01T11:00:00Z","resolved_at":null,"message":"@robin vale can you check the empty state?","order_id":"2",
       "client_meta":{"node_id":"4:5","node_offset":{"x":0,"y":0}},"reactions":[]},
      {"id":"4","file_key":"AbC123xyZ456qwe","parent_id":"","user":{"id":"300","handle":"Ines Park","img_url":""},
       "created_at":"2026-10-01T11:30:00Z","resolved_at":null,"message":"New icon set is in","order_id":"3",
       "client_meta":{"x":0,"y":0},"reactions":[]},
      {"id":"5","file_key":"AbC123xyZ456qwe","parent_id":"","user":{"id":"300","handle":"Ines Park","img_url":""},
       "created_at":"2026-10-01T11:40:00Z","resolved_at":"2026-10-01T12:00:00Z","message":"Done thread","order_id":"4",
       "client_meta":{"x":0,"y":0},"reactions":[]},
      {"id":"6","file_key":"AbC123xyZ456qwe","parent_id":"","user":{"id":"300","handle":"Ines Park","img_url":""},
       "created_at":"2026-09-01T11:40:00Z","resolved_at":null,"message":"Old","order_id":"5",
       "client_meta":{"x":0,"y":0},"reactions":[]}
    ]}
    """

    @Test func sortsCommentsIntoMentionsRepliesAndComments() throws {
        let comments = try FigmaDecoding.comments(from: Data(commentsJSON.utf8), fileKey: "AbC123xyZ456qwe")
        #expect(comments.count == 6)
        #expect(comments[0].nodeID == "12:345" && comments[0].parentID == nil)
        let items = FigmaInbox.items(comments: comments, file: "Orbit Checkout", fileKey: "AbC123xyZ456qwe", me: me, since: since)
        // Mine, resolved and older than a week are left out.
        #expect(items.map(\.id) == ["figma-c-2", "figma-c-3", "figma-c-4"])
        #expect(items.map(\.kind) == [.replied, .mentioned, .commented])
        #expect(items[0].figma?.threadID == "1" && items[0].figma?.commentID == "2")
        #expect(items[0].url.absoluteString == "https://www.figma.com/design/AbC123xyZ456qwe#1")
        #expect(items[1].url.absoluteString == "https://www.figma.com/design/AbC123xyZ456qwe?node-id=4-5#3")
        #expect(items[1].group == .mentions && items[0].group == .design && items[2].group == .design)
    }

    @Test func listsOnlyNamedVersionsBySomeoneElse() throws {
        let json = """
        {"versions":[
          {"id":"501","created_at":"2026-10-02T08:00:00Z","label":"Checkout v3","description":"New totals row","user":{"id":"200","handle":"Kai Moss","img_url":""}},
          {"id":"500","created_at":"2026-10-02T07:00:00Z","label":null,"description":null,"user":{"id":"200","handle":"Kai Moss","img_url":""}},
          {"id":"499","created_at":"2026-10-02T06:00:00Z","label":"My pass","description":"","user":{"id":"100","handle":"Robin Vale","img_url":""}}
        ],"pagination":{}}
        """
        let versions = try FigmaDecoding.versions(from: Data(json.utf8))
        let items = FigmaInbox.items(versions: versions, file: "Orbit Checkout", fileKey: "AbC123xyZ456qwe", me: me, since: since)
        #expect(items.count == 1)
        #expect(items[0].kind == .newVersion && items[0].title == "Checkout v3" && items[0].reference == "Orbit Checkout")
        #expect(items[0].url.absoluteString == "https://www.figma.com/design/AbC123xyZ456qwe?version-id=501")
        #expect(items[0].figma?.commentID == nil)
    }

    @Test func mentionsMatchTheHandleOnly() {
        #expect(FigmaInbox.mentions("ping @Robin Vale", me))
        #expect(!FigmaInbox.mentions("Robin Vale said hi", me))
        #expect(!FigmaInbox.mentions("@someone", FigmaUser(id: "1", handle: "")))
    }
}
