import Foundation

/// One thing a coding agent did, from one of its hook payloads.
///
/// Agents (Claude Code today; Codex and Gemini CLI use the same shape or
/// close to it) send a JSON object per lifecycle event. This turns that into
/// a small, readable record: which session, in which folder, and what
/// happened — "Read App.swift", "Ran swift test", "Finished".
///
/// Payloads are untrusted input: every string is cut to a sane length, and
/// nothing here is ever written to disk.
struct AgentEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionStarted
        /// The user sent a prompt; the agent is working.
        case prompt(String)
        /// A tool is about to run.
        case toolStarted(AgentStep)
        /// A tool finished, successfully or not.
        case toolFinished(tool: String, succeeded: Bool)
        /// The agent is waiting for the user (permission, a question).
        case needsAttention(String)
        /// The agent finished its turn.
        case finished
        case sessionEnded
    }

    let agent: String
    let sessionID: String
    let cwd: String?
    let kind: Kind
    let date: Date

    /// "MyHub" from "/Users/me/Code/MyHub".
    var project: String? {
        cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static let maxText = 160

    /// Parses a Claude Code style hook payload. `agent` comes from the URL the
    /// hook posted to, already validated.
    static func parse(_ data: Data, agent: String, now: Date = Date()) -> AgentEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["hook_event_name"] as? String else { return nil }
        let session = clip(object["session_id"] as? String ?? "", 80)
        guard !session.isEmpty else { return nil }
        let cwd = (object["cwd"] as? String).map { clip($0, 400) }
        let kind: Kind
        switch event {
        case "SessionStart":
            kind = .sessionStarted
        case "UserPromptSubmit", "BeforeAgent":
            kind = .prompt(firstLine(object["prompt"] as? String ?? ""))
        case "PreToolUse", "BeforeTool":
            let tool = object["tool_name"] as? String ?? "tool"
            kind = .toolStarted(AgentStep(tool: tool, input: object["tool_input"] as? [String: Any] ?? [:]))
        case "PostToolUse", "AfterTool":
            kind = .toolFinished(tool: clip(object["tool_name"] as? String ?? "tool", 60), succeeded: true)
        case "PostToolUseFailure":
            kind = .toolFinished(tool: clip(object["tool_name"] as? String ?? "tool", 60), succeeded: false)
        case "Notification":
            kind = .needsAttention(firstLine(object["message"] as? String ?? L10n.string("Waiting for you")))
        case "PermissionRequest":
            kind = .needsAttention(L10n.string("Asking for permission"))
        case "Stop", "AfterAgent":
            kind = .finished
        case "StopFailure":
            kind = .needsAttention(L10n.string("Stopped with an error"))
        case "SessionEnd":
            kind = .sessionEnded
        default:
            return nil
        }
        return AgentEvent(agent: agent, sessionID: session, cwd: cwd, kind: kind, date: now)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return clip(line.trimmingCharacters(in: .whitespaces), maxText)
    }

    /// Agent names in hook URLs: lowercase letters, digits and hyphens.
    static func isValidAgentName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9-]{1,24}$", options: .regularExpression) != nil
    }
}

/// A tool call, described the way a person would: verb, object, and the
/// symbol to show beside it.
struct AgentStep: Equatable, Sendable {
    enum Action: String, Sendable {
        case read, edit, write, run, search, web, delegate, plan, other

        var symbol: String {
            switch self {
            case .read: "doc.text"
            case .edit: "pencil"
            case .write: "doc.badge.plus"
            case .run: "terminal"
            case .search: "magnifyingglass"
            case .web: "globe"
            case .delegate: "person.2"
            case .plan: "checklist"
            case .other: "wrench.and.screwdriver"
            }
        }

        var verb: String {
            switch self {
            case .read: L10n.string("Read")
            case .edit: L10n.string("Edit")
            case .write: L10n.string("Write")
            case .run: L10n.string("Run")
            case .search: L10n.string("Search")
            case .web: L10n.string("Fetch")
            case .delegate: L10n.string("Delegate")
            case .plan: L10n.string("Plan")
            case .other: L10n.string("Use")
            }
        }
    }

    let tool: String
    let action: Action
    /// The file name, command, pattern or URL — whatever says what it did.
    let detail: String

    init(tool: String, action: Action, detail: String) {
        self.tool = tool
        self.action = action
        self.detail = detail
    }

    /// Claude Code's tools and their equivalents in Codex and Gemini CLI.
    init(tool rawTool: String, input: [String: Any]) {
        let tool = AgentEvent.clip(rawTool, 60)
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func file(_ key: String) -> String? { string(key).map { ($0 as NSString).lastPathComponent } }
        let action: Action
        var detail: String?
        switch tool {
        case "Read", "read_file", "NotebookRead", "read_many_files":
            action = .read; detail = file("file_path") ?? file("absolute_path") ?? file("path")
        case "Edit", "MultiEdit", "NotebookEdit", "replace":
            action = .edit; detail = file("file_path") ?? file("notebook_path") ?? file("path")
        case "apply_patch":
            // Codex: the files are named inside the patch text.
            action = .edit; detail = file("file_path") ?? Self.patchedFile(in: input)
        case "Write", "write_file":
            action = .write; detail = file("file_path") ?? file("path")
        case "Bash", "run_shell_command", "shell", "exec_command", "local_shell":
            action = .run; detail = string("command") ?? (input["command"] as? [String])?.joined(separator: " ")
        case "Grep", "Glob", "search_file_content", "glob", "LS", "list_directory":
            action = .search; detail = string("pattern") ?? string("path")
        case "WebFetch", "WebSearch", "web_fetch", "google_web_search":
            action = .web; detail = string("url") ?? string("query") ?? string("prompt")
        case "Task", "Agent":
            action = .delegate; detail = string("description") ?? string("subagent_type")
        case "TodoWrite", "update_plan":
            action = .plan; detail = nil
        default:
            action = .other; detail = tool.hasPrefix("mcp__") ? tool.split(separator: "_").last.map(String.init) : tool
        }
        self.init(tool: tool, action: action, detail: AgentEvent.firstLine(detail ?? ""))
    }

    /// The first file a Codex patch touches: "*** Update File: Sources/App.swift".
    static func patchedFile(in input: [String: Any]) -> String? {
        let texts = input.values.compactMap { $0 as? String } + (input.values.compactMap { $0 as? [String] }.flatMap { $0 })
        for text in texts {
            if let range = text.range(of: #"\*\*\* (Add|Update|Delete) File: [^\n]+"#, options: .regularExpression) {
                let path = text[range].split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                return (path as NSString).lastPathComponent
            }
        }
        return nil
    }

    /// "Edit App.swift", "Run swift test".
    var summary: String { detail.isEmpty ? action.verb : "\(action.verb) \(detail)" }
}
