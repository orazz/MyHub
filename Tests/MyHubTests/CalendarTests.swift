import Foundation
import Testing
@testable import MyHub

@Suite struct CallLinkDetectorTests {
    @Test(arguments: [
        ("https://meet.google.com/abc-defg-hij", "Google Meet"),
        ("https://us02web.zoom.us/j/123456789?pwd=x", "Zoom"),
        ("https://teams.microsoft.com/l/meetup-join/19%3a", "Teams"),
        ("https://acme.webex.com/meet/jane", "Webex"),
    ])
    func findsKnownProviders(link: String, provider: String) throws {
        let url = try #require(CallLinkDetector.find(in: ["Dial in: \(link) (passcode 1234)"]))
        #expect(CallLinkDetector.service(for: url) == provider)
    }

    @Test(arguments: [
        "http://meet.google.com/abc-defg-hij",        // not https
        "https://zoom.us.attacker.example/j/1",       // lookalike suffix
        "https://evilzoom.us/j/1",                    // lookalike prefix
        "https://example.com/?next=https://zoom.us",  // provider only in the query
        "https://user:pass@zoom.us/j/1",              // credentials in the URL
    ])
    func rejectsAnythingElse(link: String) {
        #expect(CallLinkDetector.find(in: [link]) == nil)
    }

    @Test func prefersTheFirstJoinableLinkInOrder() {
        let texts = ["Room 4B", "https://example.com/agenda https://meet.google.com/aaa-bbbb-ccc", "https://zoom.us/j/9"]
        #expect(CallLinkDetector.find(in: texts)?.host == "meet.google.com")
    }
}

@Suite struct AgendaFormatTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func countdownBeforeAndDuring() {
        let start = now.addingTimeInterval(12 * 60)
        #expect(AgendaFormat.countdown(now: now, start: start, end: start.addingTimeInterval(1800)) == "in 12 min")
        let running = now.addingTimeInterval(-600)
        #expect(AgendaFormat.countdown(now: now, start: running, end: now.addingTimeInterval(20 * 60)) == "now · 20 min left")
    }

    @Test func durationsRoundUpAndStayShort() {
        #expect(AgendaFormat.duration(30) == "1 min")
        #expect(AgendaFormat.duration(3600) == "1 h")
        #expect(AgendaFormat.duration(2 * 3600 + 5 * 60) == "2 h 5 min")
        #expect(AgendaFormat.duration(50 * 3600) == "2 d")
    }

    @Test func shortCountdown() {
        #expect(AgendaFormat.shortCountdown(now: now, start: now.addingTimeInterval(90)) == "2m")
        #expect(AgendaFormat.shortCountdown(now: now, start: now.addingTimeInterval(3 * 3600)) == "3h")
        #expect(AgendaFormat.shortCountdown(now: now, start: now.addingTimeInterval(-5)) == "now")
    }

    @Test func dayTitlesAndGrouping() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now).addingTimeInterval(10 * 3600)
        let tomorrow = today.addingTimeInterval(24 * 3600)
        #expect(AgendaFormat.dayTitle(today, now: today) == "Today")
        #expect(AgendaFormat.dayTitle(tomorrow, now: today) == "Tomorrow")

        func meeting(_ id: String, _ start: Date) -> Meeting {
            Meeting(id: id, title: id, start: start, end: start.addingTimeInterval(1800), color: RGBA(nil),
                    calendarTitle: "", link: nil, provider: nil)
        }
        let groups = AgendaFormat.byDay([meeting("a", today), meeting("b", today.addingTimeInterval(3600)), meeting("c", tomorrow)])
        #expect(groups.map { $0.meetings.map(\.id) } == [["a", "b"], ["c"]])
    }
}

@Suite struct WrappedMeetingLinkTests {
    @Test func unwrapsOutlookSafeLinksAroundTeams() throws {
        let wrapped = "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_abc%2540thread.v2%2F0&data=05%7C01&reserved=0"
        let url = try #require(CallLinkDetector.find(in: ["Join: \(wrapped)"]))
        #expect(url.host == "teams.microsoft.com")
        #expect(CallLinkDetector.service(for: url) == "Teams")
    }

    @Test func unwrapsGoogleRedirects() throws {
        let url = try #require(CallLinkDetector.find(in: ["https://www.google.com/url?q=https://meet.google.com/abc-defg-hij&sa=D"]))
        #expect(url.host == "meet.google.com")
    }

    @Test func unwrappingNeverWidensTheAllowList() {
        let evil = "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fzoom.us.attacker.example%2Fj%2F1"
        #expect(CallLinkDetector.find(in: [evil]) == nil)
        // A look-alike redirector is not a redirector.
        #expect(CallLinkDetector.find(in: ["https://safelinks.protection.outlook.com.evil.example/?url=https%3A%2F%2Fzoom.us%2Fj%2F1"]) == nil)
    }
}
