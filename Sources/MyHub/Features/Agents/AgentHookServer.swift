import Foundation
import Network

/// Receives agent hook events: `POST /hook/<agent>` with the hook's JSON as
/// the body, from a one-line `curl` in the agent's hook settings.
///
/// - Loopback interface only; nothing on the network can connect.
/// - Each request must carry the `X-MyHub-Token` written into those settings,
///   so a web page in a browser can't post fake events to it.
/// - Bodies over 1 MB, slow or malformed requests are dropped; the reply is
///   always an immediate `{}`, so an agent never waits on MyHub.
/// - Event-driven: no polling, nothing runs between events.
final class AgentHookServer: @unchecked Sendable {
    // `listener`, `onEvent` and connection state are touched only on `queue`.
    private let queue = DispatchQueue(label: "com.orazz.myhub.agent-hooks")
    private var listener: NWListener?
    private let token: String
    private let onEvent: @Sendable (_ agent: String, _ body: Data) -> Void
    /// A permission request (`POST /permission/<agent>`). The connection is
    /// held open until `answer` is called with the JSON to send back — or,
    /// after `permissionWait`, answered with `{}` ("no decision").
    private let onPermission: (@Sendable (_ agent: String, _ body: Data, _ answer: PermissionAnswer) -> Void)?

    static let maxBody = 1 << 20
    /// Under the hook's own 60 s timeout, so the agent always hears back.
    static let permissionWait: TimeInterval = 55

    init(token: String, onEvent: @escaping @Sendable (String, Data) -> Void,
         onPermission: (@Sendable (String, Data, PermissionAnswer) -> Void)? = nil) {
        self.token = token
        self.onEvent = onEvent
        self.onPermission = onPermission
    }

    /// Starts listening on `port`; throws if the port can't be used.
    func start(port: UInt16) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        // Bound to 127.0.0.1 itself, not just filtered to loopback: the
        // socket never exists on another interface, and the firewall never asks.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        let listener = try NWListener(using: parameters)
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { ready.resume() }
                case .failed(let error): if once.claim() { ready.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
        queue.sync { self.listener = listener }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    // MARK: - HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Whatever happens, a connection lives a bounded time: five seconds,
        // or a permission request's wait plus a margin.
        queue.asyncAfter(deadline: .now() + Self.permissionWait + 3) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer, maxBody: Self.maxBody) {
            case .incomplete where !complete && error == nil:
                self.receive(connection, buffer: buffer)
            case .complete(let request):
                self.handle(request, on: connection)
            default:
                self.reply(connection, status: "400 Bad Request")
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        let isPermission = request.path.hasPrefix("/permission/")
        guard request.method == "POST", request.path.hasPrefix("/hook/") || isPermission else {
            return reply(connection, status: "404 Not Found")
        }
        guard Self.matches(request.headers["x-myhub-token"], token) else {
            return reply(connection, status: "403 Forbidden")
        }
        let agent = String(request.path.drop { $0 != "/" }.dropFirst().drop { $0 != "/" }.dropFirst())
        guard AgentEvent.isValidAgentName(agent) else { return reply(connection, status: "404 Not Found") }
        if isPermission {
            guard let onPermission else { return reply(connection, status: "200 OK") }
            let answer = PermissionAnswer { [weak self] json in
                guard let self else { return }
                self.queue.async { self.reply(connection, status: "200 OK", body: json) }
            }
            // Nobody decided in time: no decision, the agent asks as usual.
            queue.asyncAfter(deadline: .now() + Self.permissionWait) { answer.send("{}") }
            onPermission(agent, request.body, answer)
            return
        }
        reply(connection, status: "200 OK")
        // Short-lived connections close right away; only permissions wait.
        onEvent(agent, request.body)
    }

    private func reply(_ connection: NWConnection, status: String, body: String = "{}") {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Compares every byte, so timing says nothing about how much matched.
    static func matches(_ given: String?, _ expected: String) -> Bool {
        guard let given, given.utf8.count == expected.utf8.count, !expected.isEmpty else { return false }
        return zip(given.utf8, expected.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The way back to an agent waiting on a permission request. Sends once;
/// later calls (a click after the timeout, say) do nothing.
final class PermissionAnswer: @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private var sent = false
    private let deliver: @Sendable (String) -> Void

    init(_ deliver: @escaping @Sendable (String) -> Void) {
        self.deliver = deliver
    }

    /// Returns false if an answer already went out.
    @discardableResult
    func send(_ json: String) -> Bool {
        lock.lock()
        let first = !sent
        sent = true
        lock.unlock()
        if first { deliver(json) }
        return first
    }
}

/// Just enough HTTP/1.1 to read one small POST.
struct HTTPRequest: Equatable {
    let method: String
    let path: String
    /// Lowercased names.
    let headers: [String: String]
    let body: Data

    enum Result: Equatable {
        case incomplete
        case invalid
        case complete(HTTPRequest)
    }

    static func parse(_ data: Data, maxBody: Int) -> Result {
        guard let headerEnd = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16 * 1024 ? .invalid : .incomplete
        }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Only fixed-length bodies; `curl --data-binary` always sends one.
        if headers["transfer-encoding"] != nil { return .invalid }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBody else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        let path = String(requestLine[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return .complete(HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: Data(body)))
    }
}

/// True only for the first caller. Used from one serial queue.
private final class Once: @unchecked Sendable {
    private var done = false
    func claim() -> Bool {
        defer { done = true }
        return !done
    }
}
