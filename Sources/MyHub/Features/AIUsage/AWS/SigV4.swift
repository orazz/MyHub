import CryptoKit
import Foundation

struct AWSCredentials: Sendable {
    let accessKeyID: String
    let secret: Redacted<String>
    let sessionToken: Redacted<String>?
}

/// AWS Signature Version 4, written out rather than pulled in as an SDK
/// (no dependencies). Verified against AWS's published test vectors.
enum SigV4 {
    static func sign(_ request: URLRequest, credentials: AWSCredentials, region: String, service: String, now: Date = Date()) -> URLRequest {
        var request = request
        guard let url = request.url, let host = url.host else { return request }
        let (amzDate, day) = stamps(now)
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken {
            request.setValue(token.exposed, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        headers["host"] = url.port.map { "\(host):\($0)" } ?? host
        let names = headers.keys.sorted()
        let signedHeaders = names.joined(separator: ";")

        let canonical = [
            request.httpMethod ?? "GET",
            canonicalPath(url),
            canonicalQuery(url),
            names.map { "\($0):\(headers[$0]!)\n" }.joined(),
            signedHeaders,
            hex(SHA256.hash(data: request.httpBody ?? Data())),
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        let signature = hex(HMAC<SHA256>.authenticationCode(
            for: Data(toSign.utf8),
            using: signingKey(secret: credentials.secret, day: day, region: region, service: service)
        ))
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    static func signingKey(secret: Redacted<String>, day: String, region: String, service: String) -> SymmetricKey {
        func mac(_ key: SymmetricKey, _ text: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)))
        }
        var key = SymmetricKey(data: Data(("AWS4" + secret.exposed).utf8))
        for part in [day, region, service, "aws4_request"] { key = mac(key, part) }
        return key
    }

    static func stamps(_ date: Date) -> (amzDate: String, day: String) {
        let c = UTCDay.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        return (day + String(format: "T%02d%02d%02dZ", c.hour!, c.minute!, c.second!), day)
    }

    private static func canonicalPath(_ url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        return path.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }

    private static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pairs: [(name: String, value: String)] = items.map { (encode($0.name), encode($0.value ?? "")) }
        let sorted = pairs.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    /// RFC 3986: only unreserved characters stay as they are.
    static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
