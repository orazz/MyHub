import SwiftUI

/// The Agents tab: running coding-agent sessions on the left, the chosen
/// session's steps on the right, newest first.
struct AgentsView: View {
    let agents: AgentStore
    let shield: ContentShield

    var body: some View {
        if let approval = agents.approvals.first {
            // A decision is waiting: it takes the whole tab until answered.
            ApprovalCard(approval: approval, waiting: agents.approvals.count, agents: agents)
        } else if !agents.claudeInstalled {
            SetupCard(agents: agents)
        } else {
            HStack(alignment: .top, spacing: 10) {
                SessionList(agents: agents, shield: shield).frame(width: 236)
                if let session = agents.selected {
                    Timeline(session: session, agents: agents, shield: shield)
                } else {
                    EmptyPaneHint(symbol: "terminal",
                                  text: L10n.string("Start Claude Code in a terminal; its sessions appear here as they work."))
                        .hubCard()
                }
            }
        }
    }
}

extension AgentSession {
    var agentName: String {
        switch agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "gemini": "Gemini CLI"
        default: agent.capitalized
        }
    }

    var agentColor: Color {
        switch agent {
        case "claude": Color(hex: 0xE08A68)
        case "codex": Color(hex: 0x7FD1B9)
        case "gemini": Color(hex: 0x8AB4F8)
        default: HubTheme.Palette.soft
        }
    }

    var stateColor: Color {
        switch state {
        case .working: HubTheme.Palette.amber
        case .waiting: HubTheme.Palette.blue
        case .done: HubTheme.Palette.success
        case .ended: HubTheme.Palette.iconInactive
        }
    }

    /// "Edit App.swift", "Waiting: needs permission", "Done".
    var stateText: String {
        switch state {
        case .working: current?.step.summary ?? L10n.string("Thinking…")
        case .waiting(let message): message
        case .done: L10n.string("Done")
        case .ended: L10n.string("Ended")
        }
    }
}

/// A permission request: what the agent wants to do, how long is left, and
/// the three answers. Allow and Deny decide; "Ask in terminal" leaves it to
/// the agent's own prompt — as does doing nothing.
private struct ApprovalCard: View {
    let approval: AgentApproval
    let waiting: Int
    let agents: AgentStore
    /// The panel opens by itself for a request; a click already on its way
    /// must not land on Allow.
    @State private var armedFor: UUID?

    private var agentName: String {
        AgentSession(agent: approval.agent, sessionID: "", started: .now, lastEvent: .now, turnStarted: .now).agentName
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(HubTheme.Palette.blue)
                Text(L10n.format("%@ asks to", agentName)).font(HubTheme.Font.bodyStrong)
                if let project = approval.project {
                    Text("· \(project)").font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.secondary)
                }
                Spacer(minLength: 6)
                if waiting > 1 {
                    Text(L10n.format("%d waiting", waiting)).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(L10n.format("%ds", max(0, Int(approval.deadline.timeIntervalSince(context.date)))))
                        .font(HubTheme.Font.meta).monospacedDigit().foregroundStyle(HubTheme.Palette.tertiary)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: approval.step.action.symbol).font(.system(size: 16)).foregroundStyle(HubTheme.Palette.soft)
                VStack(alignment: .leading, spacing: 3) {
                    Text(approval.step.action.verb).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary)
                    Text(approval.step.detail.isEmpty ? approval.step.tool : approval.step.detail)
                        .font(approval.step.action == .run ? .system(size: 13, design: .monospaced) : .system(size: 13, weight: .medium))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x0B0B0D)))
            HStack(spacing: 8) {
                GhostPill(title: L10n.string("Deny"), symbol: "xmark", tint: HubTheme.Palette.danger) { agents.resolve(approval.id, .deny) }
                GhostPill(title: L10n.string("Ask in terminal"), symbol: "terminal") { agents.resolve(approval.id, .askInTerminal) }
                Spacer(minLength: 6)
                Button(L10n.string("Allow")) { agents.resolve(approval.id, .allow) }
                    .buttonStyle(LightCapsuleButtonStyle())
                    .disabled(armedFor != approval.id)
                    .task(id: approval.id) {
                        armedFor = nil
                        try? await Task.sleep(for: .milliseconds(600))
                        if !Task.isCancelled { armedFor = approval.id }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .hubCard()
    }
}

/// Before any agent is connected: what connecting does, and a row per agent.
private struct SetupCard: View {
    let agents: AgentStore

    var body: some View {
        VStack(spacing: 8) {
            Text(L10n.string("See your coding agents in the notch")).font(.system(size: 14, weight: .medium))
            Text(L10n.string("MyHub adds one hook to the agent's settings (a backup is kept). The agent then tells MyHub, on this Mac only, what each session reads, edits and runs. Nothing is stored or sent anywhere."))
                .font(HubTheme.Font.meta)
                .foregroundStyle(Color(hex: 0x7D7E83))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            HStack(spacing: 8) {
                ForEach(AgentHookInstaller.Target.all) { target in
                    AgentConnectTile(target: target, agents: agents)
                }
            }
            if let problem = agents.problem {
                Text(problem).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.danger).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hubCard()
    }
}

/// One agent: its name, whether it's on this Mac, and Connect.
private struct AgentConnectTile: View {
    let target: AgentHookInstaller.Target
    let agents: AgentStore

    var body: some View {
        let sample = AgentSession(agent: target.id, sessionID: "", started: .now, lastEvent: .now, turnStarted: .now)
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(sample.agentColor).frame(width: 7, height: 7)
                Text(target.name).font(HubTheme.Font.bodyStrong)
            }
            Text(target.looksInstalled ? "~/\(target.settingsPath)" : L10n.string("Not found on this Mac"))
                .font(HubTheme.Font.axis).foregroundStyle(HubTheme.Palette.tertiary).lineLimit(1).truncationMode(.middle)
            Button(L10n.string("Connect")) { agents.connect(target) }
                .buttonStyle(LightCapsuleButtonStyle())
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .frame(width: 160)
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.eventCard, style: .continuous).fill(HubTheme.Palette.selected))
    }
}

private struct SessionList: View {
    let agents: AgentStore
    let shield: ContentShield

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(agents.listening ? HubTheme.Palette.success : HubTheme.Palette.danger).frame(width: 6, height: 6)
                Text(agents.listening ? L10n.string("Listening") : L10n.string("Not listening"))
                    .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary)
                Spacer(minLength: 4)
                if agents.sessions.contains(where: { $0.state == .done || $0.state == .ended }) {
                    Button(L10n.string("Clear done")) { agents.clearFinished() }
                        .buttonStyle(.plain).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.secondary)
                }
            }
            .padding(.horizontal, 4)
            if let problem = agents.problem {
                Text(problem).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.danger).lineLimit(3)
            }
            if agents.sessions.isEmpty {
                Text(L10n.string("No sessions yet. Start a new session in a connected agent — it appears here as it works. Codex asks you to trust new hooks once (/hooks)."))
                    .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary)
                    .padding(.horizontal, 4)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(agents.sessions) { session in
                            SessionRow(session: session, selected: agents.selected?.id == session.id,
                                       hidden: shield.masks(session.id, in: .agents))
                                .onTapGesture { agents.selectedID = session.id }
                        }
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let selected: Bool
    let hidden: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Circle().fill(session.agentColor.opacity(0.18)).frame(width: 30, height: 30)
                    .overlay(Text(String(session.agentName.prefix(1))).font(.system(size: 13, weight: .bold)).foregroundStyle(session.agentColor))
                Circle().fill(session.stateColor).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project ?? session.agentName).font(HubTheme.Font.bodyStrong).lineLimit(1)
                ShieldedText(text: session.stateText, hidden: hidden, font: HubTheme.Font.meta,
                             color: session.state == .working ? HubTheme.Palette.soft : HubTheme.Palette.tertiary)
            }
            Spacer(minLength: 2)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(AgentsTime.short(since: session.state == .working ? session.turnStarted : session.lastEvent, now: context.date))
                    .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .selectedRow(selected)
        .contentShape(Rectangle())
    }
}

private struct Timeline: View {
    let session: AgentSession
    let agents: AgentStore
    let shield: ContentShield

    private var hidden: Bool { shield.masks(session.id, in: .agents) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(session.agentColor).frame(width: 8, height: 8)
                Text(session.agentName).font(HubTheme.Font.bodyStrong)
                if let project = session.project {
                    Text("· \(project)").font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(session.stateLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(session.stateColor)
                    .padding(.vertical, 2).padding(.horizontal, 7)
                    .background(Capsule().fill(session.stateColor.opacity(0.15)))
                if session.cwd != nil {
                    Button { agents.openFolder(session) } label: { Image(systemName: "terminal") }
                        .buttonStyle(HubIconButtonStyle(size: 22, filled: true))
                        .help(L10n.string("Open the project folder in Terminal"))
                }
            }
            if let prompt = session.prompt, !prompt.isEmpty {
                ShieldedText(text: "“\(prompt)”", hidden: hidden, font: HubTheme.Font.body, color: HubTheme.Palette.soft)
            }
            if session.steps.isEmpty {
                Text(L10n.string("No steps yet.")).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(session.steps.reversed()) { step in
                            StepRow(step: step, hidden: hidden)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard()
    }
}

extension AgentSession {
    var stateLabel: String {
        switch state {
        case .working: L10n.string("Working")
        case .waiting: L10n.string("Needs you")
        case .done: L10n.string("Done")
        case .ended: L10n.string("Ended")
        }
    }
}

private struct StepRow: View {
    let step: AgentSession.Step
    let hidden: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: step.step.action.symbol)
                .font(.system(size: 11))
                .foregroundStyle(HubTheme.Palette.secondary)
                .frame(width: 16)
            Text(step.step.action.verb).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary).frame(width: 52, alignment: .leading)
            ShieldedText(text: step.step.detail.isEmpty ? step.step.tool : step.step.detail, hidden: hidden,
                         font: step.step.action == .run ? HubTheme.Font.mono : HubTheme.Font.body,
                         color: HubTheme.Palette.primary)
            Group {
                switch step.succeeded {
                case true?: Image(systemName: "checkmark").foregroundStyle(HubTheme.Palette.success)
                case false?: Image(systemName: "xmark").foregroundStyle(HubTheme.Palette.danger)
                case nil: Circle().fill(HubTheme.Palette.amber).frame(width: 6, height: 6)
                }
            }
            .font(.system(size: 10, weight: .bold))
            .frame(width: 14)
            Text(step.date.formatted(date: .omitted, time: .standard))
                .font(HubTheme.Font.axis).foregroundStyle(HubTheme.Palette.tertiary).monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

enum AgentsTime {
    /// "now", "12s", "4m", "2h".
    static func short(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<10: return L10n.string("now")
        case ..<60: return "\(Int(seconds))s"
        case ..<3600: return "\(Int(seconds / 60))m"
        default: return "\(Int(seconds / 3600))h"
        }
    }
}

/// The closed notch while agents work: a dot in the agent's colour and the
/// project left of the camera, the current step right of it.
struct AgentLiveView: View {
    let agents: AgentStore
    var gap: CGFloat = 150

    var body: some View {
        let focus = agents.needingAttention.first ?? agents.working.first
        HStack(spacing: 6) {
            if let approval = agents.approvals.first {
                Image(systemName: "hand.raised.fill").foregroundStyle(HubTheme.Palette.blue)
                Text(approval.project ?? L10n.string("Approval")).lineLimit(1)
                Spacer(minLength: gap)
                Text(L10n.format("Approve: %@", approval.step.summary)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(HubTheme.Palette.soft)
            } else if let focus {
                Circle().fill(focus.stateColor).frame(width: 7, height: 7)
                Text(agentsLabel(focus)).lineLimit(1)
                Spacer(minLength: gap)
                Text(focus.stateText).lineLimit(1).truncationMode(.middle).foregroundStyle(HubTheme.Palette.soft)
            }
        }
        .font(HubTheme.Font.metaStrong)
        .foregroundStyle(HubTheme.Palette.primary)
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
    }

    private func agentsLabel(_ session: AgentSession) -> String {
        let others = agents.working.count + agents.needingAttention.count - 1
        let name = session.project ?? session.agentName
        return others > 0 ? "\(name) +\(others)" : name
    }
}
