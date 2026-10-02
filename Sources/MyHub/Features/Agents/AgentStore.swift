import AppKit
import Observation

/// One agent session as MyHub sees it.
struct AgentSession: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case working
        case waiting(String)
        case done
        case ended
    }

    struct Step: Identifiable, Equatable, Sendable {
        let id: Int
        let step: AgentStep
        let date: Date
        /// nil while the tool runs.
        var succeeded: Bool?
    }

    let agent: String
    let sessionID: String
    var project: String?
    var cwd: String?
    var state: State = .working
    /// The prompt being worked on, first line only.
    var prompt: String?
    var steps: [Step] = []
    let started: Date
    var lastEvent: Date
    var turnStarted: Date

    var id: String { "\(agent):\(sessionID)" }
    var current: Step? { state == .working ? steps.last : nil }

    static let maxSteps = 100
}

/// Live agent sessions, fed by `AgentHookServer`. Nothing is stored on disk:
/// prompts and commands stay in memory and go when MyHub quits.
///
/// While at least one agent is working, the closed notch shows a pill with
/// what it's doing. When one finishes its turn, the notch flashes.
@MainActor
@Observable
final class AgentStore {
    private(set) var sessions: [AgentSession] = []
    var selectedID: String?
    private(set) var listening = false
    private(set) var problem: String?
    /// Permission requests waiting for an answer, oldest first.
    private(set) var approvals: [AgentApproval] = []
    @ObservationIgnored private var answers: [UUID: PermissionAnswer] = [:]
    /// A permission request arrived; the coordinator may open the panel.
    @ObservationIgnored var onApprovalRequest: ((AgentApproval) -> Void)?

    /// Agents whose hook is in their settings file.
    private(set) var connected: Set<String> = []
    var claudeInstalled: Bool { !connected.isEmpty }

    /// An agent finished its turn, or needs the user.
    @ObservationIgnored var onFinished: ((AgentSession) -> Void)?
    @ObservationIgnored var onNeedsAttention: ((AgentSession, String) -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var server: AgentHookServer?
    @ObservationIgnored private var nextStepID = 0
    @ObservationIgnored private var sweeper: Task<Void, Never>?

    /// Sessions done or quiet for this long leave the list.
    static let forgetAfter: TimeInterval = 30 * 60

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    var settings: Preferences.Agents { preferences.values.agents }
    var working: [AgentSession] { sessions.filter { $0.state == .working } }
    var needingAttention: [AgentSession] { sessions.filter { if case .waiting = $0.state { true } else { false } } }
    var selected: AgentSession? { sessions.first { $0.id == selectedID } ?? sessions.first }

    /// The closed notch has something to say.
    var showsInNotch: Bool { settings.showInNotch && (!working.isEmpty || !needingAttention.isEmpty || !approvals.isEmpty) }

    // MARK: - Lifecycle

    /// Starts the loopback receiver when any agent's hook is installed.
    func start() {
        refreshInstalled()
        guard claudeInstalled else { return }
        listen()
    }

    func stop() {
        server?.stop()
        server = nil
        listening = false
        sweeper?.cancel()
    }

    private func listen() {
        guard server == nil else { return }
        let server = AgentHookServer(token: token, onEvent: { [weak self] agent, body in
            Task { @MainActor in self?.receive(agent: agent, body: body) }
        }, onPermission: { [weak self] agent, body, answer in
            Task { @MainActor in self?.receivePermission(agent: agent, body: body, answer: answer) }
        })
        self.server = server
        let port = settings.port
        Task { [weak self] in
            do {
                try await server.start(port: port)
                self?.listening = true
                self?.problem = nil
            } catch {
                self?.server = nil
                self?.listening = false
                self?.problem = L10n.format("Port %d is in use by another app. Choose another port in Settings → Agents.", Int(port))
            }
        }
        sweeper?.cancel()
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(10))
                self?.sweep(now: Date())
            }
        }
    }

    /// The shared secret written into hook settings; made once.
    private var token: String {
        if !settings.token.isEmpty { return settings.token }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        preferences.update { $0.agents.token = fresh }
        return fresh
    }

    // MARK: - Events

    func receive(agent: String, body: Data) {
        guard let event = AgentEvent.parse(body, agent: agent) else { return }
        apply(event)
    }

    func apply(_ event: AgentEvent) {
        let key = "\(event.agent):\(event.sessionID)"
        var session = sessions.first { $0.id == key }
            ?? AgentSession(agent: event.agent, sessionID: event.sessionID, project: event.project, cwd: event.cwd,
                            started: event.date, lastEvent: event.date, turnStarted: event.date)
        session.lastEvent = event.date
        if let project = event.project { session.project = project; session.cwd = event.cwd }
        let wasWorking = session.state == .working

        switch event.kind {
        case .sessionStarted:
            session.state = .done
        case .prompt(let text):
            session.state = .working
            session.prompt = text.isEmpty ? session.prompt : text
            session.turnStarted = event.date
        case .toolStarted(let step):
            session.state = .working
            nextStepID += 1
            session.steps.append(.init(id: nextStepID, step: step, date: event.date))
            if session.steps.count > AgentSession.maxSteps { session.steps.removeFirst(session.steps.count - AgentSession.maxSteps) }
        case .toolFinished(let tool, let succeeded):
            if let index = session.steps.lastIndex(where: { $0.step.tool == tool && $0.succeeded == nil }) {
                session.steps[index].succeeded = succeeded
            }
        case .needsAttention(let message):
            session.state = .waiting(message)
            onNeedsAttention?(session, message)
        case .finished:
            session.state = .done
            if wasWorking { onFinished?(session) }
        case .sessionEnded:
            session.state = .ended
        }

        if let index = sessions.firstIndex(where: { $0.id == key }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        // Most recent activity first.
        sessions.sort { $0.lastEvent > $1.lastEvent }
    }

    // MARK: - Approvals

    func receivePermission(agent: String, body: Data, answer: PermissionAnswer) {
        // Only when the user turned approvals on, and only for Claude Code;
        // otherwise "no decision" goes straight back.
        guard settings.approvals, agent == AgentHookInstaller.Target.claude.id,
              let approval = AgentApproval.parse(body, agent: agent) else {
            answer.send(ApprovalReply.askInTerminal.json)
            return
        }
        approvals.append(approval)
        answers[approval.id] = answer
        onApprovalRequest?(approval)
        // When the hook's wait runs out, the server answers "no decision";
        // the card goes at the same moment.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, approval.deadline.timeIntervalSinceNow)))
            self?.resolve(approval.id, .askInTerminal)
        }
    }

    /// The user's answer. Only ever called from a button.
    func resolve(_ id: UUID, _ reply: ApprovalReply) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        approvals.remove(at: index)
        answers.removeValue(forKey: id)?.send(reply.json)
    }

    func setApprovals(_ on: Bool) {
        preferences.update { $0.agents.approvals = on }
        // The permission hook is added or removed with the rest.
        if isConnected(.claude) { connect(.claude) }
        if !on { for approval in approvals { resolve(approval.id, .askInTerminal) } }
    }

    func setOpenForApprovals(_ on: Bool) { preferences.update { $0.agents.openForApprovals = on } }

    /// Drops sessions that ended or went quiet.
    func sweep(now: Date) {
        sessions.removeAll { session in
            let quiet = now.timeIntervalSince(session.lastEvent)
            return session.state == .ended ? quiet > 60 : quiet > Self.forgetAfter
        }
    }

    func clearFinished() {
        sessions.removeAll { $0.state == .done || $0.state == .ended }
    }

    // MARK: - Hooks

    func refreshInstalled() {
        #if DEBUG
        if previewing { return }
        #endif
        connected = Set(AgentHookInstaller.Target.all.filter(AgentHookInstaller.isInstalled).map(\.id))
    }

    func isConnected(_ target: AgentHookInstaller.Target) -> Bool { connected.contains(target.id) }

    /// Adds MyHub's hook to the agent's settings. Claude Code and Gemini pick
    /// it up in new sessions; Codex asks the user to trust it once.
    func connect(_ target: AgentHookInstaller.Target) {
        do {
            try AgentHookInstaller.install(target, port: settings.port, token: token, approvals: settings.approvals)
            problem = nil
        } catch AgentHookInstaller.Failure.notAnObject {
            problem = L10n.format("~/%@ isn't valid JSON, so MyHub left it alone. Fix it and try again.", target.settingsPath)
        } catch {
            problem = L10n.format("Couldn't update ~/%@.", target.settingsPath)
        }
        refreshInstalled()
        if !connected.isEmpty { listen() }
    }

    func disconnect(_ target: AgentHookInstaller.Target) {
        do {
            try AgentHookInstaller.uninstall(target)
        } catch {
            problem = L10n.format("Couldn't update ~/%@.", target.settingsPath)
        }
        refreshInstalled()
        if connected.isEmpty { stop() }
    }

    func installClaude() { connect(.claude) }
    func removeClaude() { disconnect(.claude) }

    func setShowInNotch(_ on: Bool) { preferences.update { $0.agents.showInNotch = on } }
    func setFlashOnFinish(_ on: Bool) { preferences.update { $0.agents.flashOnFinish = on } }

    /// A new port is written into the hook settings too, then listened on.
    func setPort(_ port: UInt16) {
        guard port >= 1024, port != settings.port else { return }
        preferences.update { $0.agents.port = port }
        stop()
        // The port is written into every connected agent's settings.
        for target in AgentHookInstaller.Target.all where connected.contains(target.id) { connect(target) }
    }

    // MARK: - Actions

    /// Opens the session's folder in Terminal.
    func openFolder(_ session: AgentSession) {
        guard let cwd = session.cwd, FileManager.default.fileExists(atPath: cwd),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: cwd, isDirectory: true)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    #if DEBUG
    @ObservationIgnored private var previewing = false

    func injectForPreview(_ sessions: [AgentSession], connected: Set<String> = ["claude"], approvals: [AgentApproval] = []) {
        previewing = true
        self.approvals = approvals
        self.sessions = sessions
        self.connected = connected
        listening = true
    }
    #endif
}
