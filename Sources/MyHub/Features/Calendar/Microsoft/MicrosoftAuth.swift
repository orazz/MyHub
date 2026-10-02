import CryptoKit
import Foundation
import Network

/// Signing in to Microsoft 365 the way Microsoft documents for desktop apps:
/// OAuth 2.0 authorization code with PKCE, in the user's default browser, the
/// answer caught on a loopback address. A desktop app is a "public client" —
/// it has no secret to keep, so none is involved.
///
/// - `client_id` is the app registration's Application ID (not a secret);
///   the registration allows work, school and personal accounts and has the
///   redirect URI `http://localhost` (Microsoft ignores the port for it).
/// - Scopes: `Calendars.Read` (read only), `User.Read` (the account name),
///   `offline_access` (a refresh token, so the user signs in once).
/// - The refresh token goes to the Keychain; access tokens stay in memory.
enum MicrosoftAuth {
    static let tenant = "common"
    static let scopes = "offline_access User.Read Calendars.Read"
    static let hosts: Set<String> = ["login.microsoftonline.com", "graph.microsoft.com"]
    static let refreshTokenAccount = "microsoft.refresh"

    /// A fresh PKCE pair: a random verifier and its S256 challenge.
    struct PKCE: Sendable {
        let verifier: String
        let challenge: String

        init(verifier: String = PKCE.randomVerifier()) {
            self.verifier = verifier
            challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        static func randomVerifier() -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return base64URL(Data(bytes))
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    static func authorizeURL(clientID: String, redirect: String, pkce: PKCE, state: String) -> URL? {
        var components = URLComponents(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components?.url
    }

    enum CallbackError: Error, Equatable {
        case stateMismatch
        case denied(String)
        case missingCode
    }

    /// The `code` from the browser's redirect, after checking it answers our
    /// own request (`state`) and isn't an error.
    static func code(fromCallbackQuery query: String, expectedState: String) throws -> String {
        let items = URLComponents(string: "http://localhost/?" + query)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { throw CallbackError.stateMismatch }
        if let error = value("error") {
            throw CallbackError.denied(value("error_description") ?? error)
        }
        guard let code = value("code"), !code.isEmpty else { throw CallbackError.missingCode }
        return code
    }

    struct Tokens: Sendable {
        let access: Redacted<String>
        let refresh: Redacted<String>?
        let expires: Date
    }

    private struct TokenDTO: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
    }

    static func tokens(from data: Data, now: Date = Date()) throws -> Tokens {
        let dto = try JSONDecoder().decode(TokenDTO.self, from: data)
        // A minute early, so a token never expires between check and use.
        return Tokens(access: Redacted(dto.access_token), refresh: dto.refresh_token.map(Redacted.init),
                      expires: now.addingTimeInterval(max(0, dto.expires_in - 60)))
    }

    /// The token endpoint, form-encoded: exchange a code, or refresh.
    static func requestTokens(clientID: String, grant: [String: String]) async throws -> Tokens {
        guard let url = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token") else {
            throw UsageError.refused(L10n.string("Invalid URL."))
        }
        var fields = grant
        fields["client_id"] = clientID
        fields["scope"] = scopes
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(fields).utf8)
        let data = try await HTTPClient(allowedHosts: hosts).send(request)
        return try tokens(from: data)
    }

    static func formEncode(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}

/// A one-shot HTTP listener on the loopback interface that waits for the
/// browser's redirect after sign-in.
///
/// Bound to loopback only — nothing on the network can reach it — on a port
/// the system picks. It answers the first request with a short "you can close
/// this tab" page, hands back the query string, and stops.
final class LoopbackRedirect: @unchecked Sendable {
    // All state below is touched only on `queue`.
    private let queue = DispatchQueue(label: "com.orazz.myhub.loopback")
    private let listener: NWListener
    private var continuation: CheckedContinuation<String, Error>?
    /// Set once; kept in case the redirect arrives before anyone waits.
    private var result: Result<String, Error>?

    private init(listener: NWListener) {
        self.listener = listener
    }

    /// Starts listening; returns once the port is known.
    static func start() async throws -> LoopbackRedirect {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let redirect = LoopbackRedirect(listener: listener)
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { ready.resume() }
                case .failed(let error): if once.claim() { ready.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak redirect] connection in redirect?.accept(connection) }
            listener.start(queue: redirect.queue)
        }
        return redirect
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var redirectURI: String { "http://127.0.0.1:\(port)" }

    /// The query string of the first request, or an error after `timeout`.
    func waitForCallback(timeout: Duration = .seconds(300)) async throws -> String {
        let seconds = Double(timeout.components.seconds)
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.finish(.failure(CancellationError()))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(with: result)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // "GET /?code=…&state=… HTTP/1.1"
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let query = target.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
            let page = query == nil
                ? "Not found"
                : "<!doctype html><meta charset=utf-8><title>MyHub</title><body style=\"font:15px -apple-system;padding:40px\">Signed in — you can close this tab and return to MyHub.</body>"
            let status = query == nil ? "404 Not Found" : "200 OK"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let query { self.finish(.success(query)) }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        listener.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// True the first time `claim` is called, false after. Only used from the
/// listener's queue.
private final class OnceFlag: @unchecked Sendable {
    private var claimed = false
    func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}
