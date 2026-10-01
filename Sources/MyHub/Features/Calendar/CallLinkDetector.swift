import Foundation

/// Picks the video-call link out of an event and decides whether MyHub will
/// offer it as a one-click "Join".
///
/// Invitations come from other people — sometimes strangers — so a link in
/// one is untrusted input. It earns a button only when it is `https`, carries
/// no credentials, and its host is one of the call services below or a
/// subdomain of one. A host that merely contains a service's name
/// (`zoom.us.example.com`, `notzoom.us`) does not count. Events with other
/// links still show; they just get no button.
enum CallLinkDetector {
    /// Call services and the hosts their meeting links live on.
    static let services: KeyValuePairs<String, [String]> = [
        "Around": ["around.co"],
        "Chime": ["chime.aws"],
        "Discord": ["discord.gg"],
        "Gather": ["gather.town"],
        "Google Meet": ["meet.google.com"],
        "Jitsi": ["meet.jit.si"],
        "Slack": ["app.slack.com"],
        "Teams": ["teams.microsoft.com", "teams.live.com"],
        "Webex": ["webex.com"],
        "Whereby": ["whereby.com"],
        "Zoom": ["zoom.us", "zoomgov.com"],
    ]

    /// The first acceptable link across `texts` (location, then notes, then
    /// the URL field — the caller's order is the priority).
    static func find(in texts: [String]) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return texts.lazy
            .flatMap { text in
                (detector?.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? [])
                    .compactMap(\.url)
            }
            .map(unwrapped)
            .first(where: isJoinable)
    }

    /// Mail filters rewrite links in invitations to pass through a checker
    /// first: Microsoft 365's Safe Links (`….safelinks.protection.outlook.com/?url=`)
    /// and Google's `google.com/url?q=`. The destination is taken out of the
    /// query and judged on its own — never the wrapper.
    static func unwrapped(_ url: URL) -> URL {
        let host = url.host?.lowercased() ?? ""
        let key: String? = switch true {
        case host.hasSuffix(".safelinks.protection.outlook.com"): "url"
        case ["google.com", "www.google.com"].contains(host) && url.path == "/url": "q"
        default: nil
        }
        guard let key,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.last(where: { $0.name == key })?.value,
              let inner = URL(string: value) else { return url }
        return inner
    }

    static func isJoinable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return false }
        return service(for: url) != nil
    }

    /// The call service a link belongs to, by exact host or subdomain.
    static func service(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        func belongs(to domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        return services.first { $0.value.contains(where: belongs) }?.key
    }
}
