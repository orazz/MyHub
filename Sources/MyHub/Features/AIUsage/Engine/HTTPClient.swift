import Foundation

/// The only way AI Usage talks to the network.
///
/// - Ephemeral session: no cookies, no cache, no credential storage.
/// - HTTPS only (plain HTTP is allowed to loopback, for local proxies).
/// - Each client is bound to an allow-list of hosts; anything else is refused
///   before a byte is sent.
/// - Redirects are never followed, so an `Authorization` header can never be
///   carried to a different host.
/// - Response bodies are capped. Nothing here logs headers or bodies.
struct HTTPClient: Sendable {
    let allowedHosts: Set<String>
    var allowsLoopbackHTTP = false

    static let maxResponseBytes = 4 * 1024 * 1024

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "MyHub/\(Bundle.main.appVersion)"]
        return URLSession(configuration: configuration)
    }()

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await send(request)
    }

    func send(_ request: URLRequest) async throws -> Data {
        try validate(request.url)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request, delegate: RedirectRefusal.shared)
        } catch let error as URLError {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse("not HTTP") }
        guard data.count <= Self.maxResponseBytes else { throw UsageError.badResponse("response too large") }
        Log.network.debug("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.host ?? "", privacy: .public)\(request.url?.path ?? "", privacy: .private) → \(http.statusCode, privacy: .public)")
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw UsageError.unauthorized
        case 429:
            let after = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: after)
        default:
            if let message = Self.errorMessage(in: data) { throw UsageError.server(http.statusCode, message) }
            throw UsageError.http(http.statusCode)
        }
    }

    func postJSON(_ url: URL, body: Data, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await send(request)
    }

    /// The explanation APIs put in error bodies (`message`, `Message`,
    /// `error.message`, `error` as a string), trimmed for display.
    static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let candidates: [Any?] = [
            object["message"], object["Message"],
            (object["error"] as? [String: Any])?["message"], object["error"],
        ]
        guard let text = candidates.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else { return nil }
        return String(text.prefix(200))
    }

    func validate(_ url: URL?) throws {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            throw UsageError.refused(L10n.string("Invalid URL."))
        }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback && allowsLoopbackHTTP) else {
            throw UsageError.refused(L10n.string("Only HTTPS is allowed."))
        }
        guard allowedHosts.contains(host) else {
            throw UsageError.refused(L10n.format("Host %@ is not allowed for this source.", host))
        }
        guard url.user == nil, url.password == nil else {
            throw UsageError.refused(L10n.string("Credentials in URLs are not allowed."))
        }
    }
}

/// Refuses every redirect. API endpoints we call answer directly; a redirect
/// is either a misconfiguration or an attempt to move our headers elsewhere.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectRefusal()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// ISO 8601 as the various APIs actually send it: with or without fractional
/// seconds (of any length), `Z` or `+00:00`.
enum ISODate {
    static func parse(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: normalizedFraction(string)) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// Trims or pads fractional seconds to three digits, which is what the
    /// formatter reliably accepts ("…00.130999+00:00" → "…00.130+00:00").
    private static func normalizedFraction(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        let digits = string[string.index(after: dot)...].prefix { $0.isNumber }
        let fixed = String((digits + "000").prefix(3))
        return string[..<dot] + "." + fixed + string[digits.endIndex...]
    }
}
