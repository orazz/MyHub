import Foundation

/// A coding agent asking permission to use a tool, waiting for an answer
/// from the notch.
struct AgentApproval: Identifiable, Equatable, Sendable {
    let id: UUID
    let agent: String
    let sessionID: String
    let project: String?
    let step: AgentStep
    let received: Date
    let deadline: Date

    /// From a `PermissionRequest` hook payload.
    static func parse(_ data: Data, agent: String, now: Date = Date(),
                      wait: TimeInterval = AgentHookServer.permissionWait) -> AgentApproval? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = object["tool_name"] as? String else { return nil }
        let session = AgentEvent.clip(object["session_id"] as? String ?? "", 80)
        let cwd = object["cwd"] as? String
        return AgentApproval(
            id: UUID(), agent: agent, sessionID: session,
            project: cwd.map { ($0 as NSString).lastPathComponent },
            step: AgentStep(tool: tool, input: object["tool_input"] as? [String: Any] ?? [:]),
            received: now, deadline: now.addingTimeInterval(wait - 1)
        )
    }
}

/// What MyHub sends back to Claude Code's `PermissionRequest` hook.
enum ApprovalReply {
    case allow
    case deny
    /// No decision: Claude Code shows its own prompt, as if MyHub weren't there.
    case askInTerminal

    var json: String {
        switch self {
        case .allow:
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case .deny:
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from MyHub"}}}"#
        case .askInTerminal:
            "{}"
        }
    }
}
