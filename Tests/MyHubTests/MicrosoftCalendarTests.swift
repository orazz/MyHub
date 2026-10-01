import Foundation
import Testing
@testable import MyHub

@Suite struct MicrosoftAuthTests {
    @Test func pkceMatchesTheRFC7636Example() {
        let pkce = MicrosoftAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let random = MicrosoftAuth.PKCE()
        #expect(random.verifier.count >= 43)
        #expect(!random.verifier.contains("=") && !random.verifier.contains("+"))
    }

    @Test func authorizeURLAsksForReadOnlyCalendarWithPKCE() throws {
        let url = try #require(MicrosoftAuth.authorizeURL(clientID: "11111111-2222-3333-4444-555555555555",
                                                          redirect: "http://localhost:54321", pkce: .init(verifier: "v"), state: "s"))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "login.microsoftonline.com")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["scope"] == "offline_access User.Read Calendars.Read")
        #expect(items["redirect_uri"] == "http://localhost:54321")
        #expect(items["state"] == "s")
    }

    @Test func callbackIsCheckedBeforeUse() throws {
        #expect(try MicrosoftAuth.code(fromCallbackQuery: "code=abc&state=s1", expectedState: "s1") == "abc")
        #expect(throws: MicrosoftAuth.CallbackError.stateMismatch) {
            try MicrosoftAuth.code(fromCallbackQuery: "code=abc&state=evil", expectedState: "s1")
        }
        #expect(throws: MicrosoftAuth.CallbackError.denied("User declined")) {
            try MicrosoftAuth.code(fromCallbackQuery: "error=access_denied&error_description=User%20declined&state=s1", expectedState: "s1")
        }
        #expect(throws: MicrosoftAuth.CallbackError.missingCode) {
            try MicrosoftAuth.code(fromCallbackQuery: "state=s1", expectedState: "s1")
        }
    }

    @Test func tokensExpireAMinuteEarly() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tokens = try MicrosoftAuth.tokens(from: Data(#"{"token_type":"Bearer","access_token":"A","refresh_token":"R","expires_in":3600}"#.utf8), now: now)
        #expect(tokens.access.exposed == "A" && tokens.refresh?.exposed == "R")
        #expect(tokens.expires == now.addingTimeInterval(3540))
        #expect(MicrosoftAuth.formEncode(["b": "a b&c", "a": "x=y"]) == "a=x%3Dy&b=a%20b%26c")
    }

    @Test func loopbackCatchesTheBrowserRedirect() async throws {
        let redirect = try await LoopbackRedirect.start()
        #expect(redirect.port > 0)
        async let query = redirect.waitForCallback(timeout: .seconds(10))
        let url = try #require(URL(string: "http://127.0.0.1:\(redirect.port)/?code=xyz&state=s9"))
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("close this tab"))
        #expect(try await query == "code=xyz&state=s9")
    }
}

@Suite struct MicrosoftCalendarDecodingTests {
    let json = """
    {"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=abc","value":[
      {"id":"A","subject":"Standup","start":{"dateTime":"2026-10-02T09:00:00.0000000","timeZone":"UTC"},
       "end":{"dateTime":"2026-10-02T09:15:00.0000000","timeZone":"UTC"},"isAllDay":false,"isCancelled":false,
       "location":{"displayName":"Microsoft Teams Meeting"},"isOnlineMeeting":true,"onlineMeetingProvider":"teamsForBusiness",
       "onlineMeeting":{"joinUrl":"https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"},
       "responseStatus":{"response":"accepted"},"attendees":[{},{},{}]},
      {"id":"B","subject":"Offsite","start":{"dateTime":"2026-10-03T00:00:00.0000000","timeZone":"UTC"},
       "end":{"dateTime":"2026-10-04T00:00:00.0000000","timeZone":"UTC"},"isAllDay":true},
      {"id":"C","subject":"Cancelled sync","start":{"dateTime":"2026-10-02T10:00:00.0000000","timeZone":"UTC"},
       "end":{"dateTime":"2026-10-02T10:30:00.0000000","timeZone":"UTC"},"isCancelled":true},
      {"id":"D","subject":"Declined","start":{"dateTime":"2026-10-02T11:00:00.0000000","timeZone":"UTC"},
       "end":{"dateTime":"2026-10-02T11:30:00.0000000","timeZone":"UTC"},"responseStatus":{"response":"declined"}},
      {"id":"E","subject":"Phishy","start":{"dateTime":"2026-10-02T12:00:00.0000000","timeZone":"UTC"},
       "end":{"dateTime":"2026-10-02T12:30:00.0000000","timeZone":"UTC"},"location":{"displayName":"Room 4"},
       "onlineMeeting":{"joinUrl":"https://teams.microsoft.com.evil.example/join"}}
    ]}
    """

    @Test func keepsTimedMeetingsWithSafeJoinLinks() throws {
        let page = try MicrosoftCalendar.page(from: Data(json.utf8))
        #expect(page.meetings.map(\.title) == ["Standup", "Phishy"])
        let standup = page.meetings[0]
        #expect(standup.start == ISODate.parse("2026-10-02T09:00:00Z"))
        #expect(standup.link?.host == "teams.microsoft.com")
        #expect(standup.provider == "Teams")
        #expect(standup.location == nil)   // "Microsoft Teams Meeting" is the call, not a place
        #expect(standup.attendees == 3)
        #expect(page.meetings[1].link == nil)
        #expect(page.meetings[1].location == "Room 4")
        #expect(page.next?.host == "graph.microsoft.com")
    }

    @Test func foreignNextLinksAreDropped() throws {
        let data = Data(#"{"@odata.nextLink":"https://evil.example/next","value":[]}"#.utf8)
        #expect(try MicrosoftCalendar.page(from: data).next == nil)
    }

    @Test func calendarViewURLAsksForUTCWeek() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try #require(MicrosoftCalendar.calendarViewURL(from: start, to: start.addingTimeInterval(7 * 86400)))
        #expect(url.host == "graph.microsoft.com" && url.path == "/v1.0/me/calendarView")
        #expect(url.absoluteString.contains("onlineMeeting"))
    }

    @Test func theSameMeetingFromBothSourcesShowsOnce() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func meeting(_ id: String, _ title: String, _ offset: TimeInterval, link: URL?) -> Meeting {
            Meeting(id: id, title: title, start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + 900),
                    color: MicrosoftCalendar.color, calendarTitle: "", link: link, provider: nil)
        }
        let teams = URL(string: "https://teams.microsoft.com/l/meetup-join/x")!
        let merged = MicrosoftCalendar.merge(
            [meeting("local-1", "Standup", 0, link: nil), meeting("local-2", "Lunch", 3600, link: nil)],
            [meeting("ms-1", "standup ", 20, link: teams), meeting("ms-2", "1:1", 1800, link: teams)]
        )
        #expect(merged.map(\.id) == ["ms-1", "ms-2", "local-2"])
    }
}
