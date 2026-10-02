import Foundation

/// Adds MyHub's hook to an agent's settings file, and takes it out again.
///
/// The hook is one `curl` that forwards the event JSON (stdin) to MyHub's
/// loopback port, marked `async` so the agent never waits for it. It always
/// exits 0, so with MyHub not running the agent sees nothing at all.
///
/// The settings file belongs to the user and the agent:
/// - everything else in it is kept as it was;
/// - a copy is saved next to it before MyHub first changes it;
/// - a file that isn't valid JSON is never written;
/// - MyHub's entries are recognised by their URL, so installing twice adds
///   nothing and removing takes out only what MyHub added.
enum AgentHookInstaller {
    enum Failure: Error, Equatable {
        case unreadable
        case notAnObject
    }

    /// An agent MyHub can connect to: where its hook settings live, which of
    /// its events to forward, and the shape of one hook entry.
    struct Target: Identifiable, Sendable {
        let id: String
        let name: String
        /// Relative to the home folder.
        let settingsPath: String
        let events: [String]
        /// Gemini CLI wants a JSON answer on stdout and runs hooks in line;
        /// the others take `async` and ignore stdout.
        let inline: Bool

        var settings: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(settingsPath) }
        /// The agent's own folder exists, so it's probably installed.
        var looksInstalled: Bool { FileManager.default.fileExists(atPath: settings.deletingLastPathComponent().path) }

        func handler(port: UInt16, token: String) -> [String: Any] {
            let forward = AgentHookInstaller.command(port: port, agent: id, token: token)
            if inline {
                // Timeout in milliseconds here; stdout must be JSON only.
                return ["type": "command", "name": "myhub", "command": forward + "; printf '{}'", "timeout": 3000]
            }
            return ["type": "command", "command": forward, "async": true, "timeout": 5]
        }

        static let claude = Target(
            id: "claude", name: "Claude Code", settingsPath: ".claude/settings.json",
            events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                     "Notification", "Stop", "StopFailure", "SessionEnd"],
            inline: false)
        /// Codex reads `~/.codex/hooks.json` and asks the user to trust new
        /// hooks once (`/hooks` in Codex).
        static let codex = Target(
            id: "codex", name: "Codex", settingsPath: ".codex/hooks.json",
            events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd"],
            inline: false)
        static let gemini = Target(
            id: "gemini", name: "Gemini CLI", settingsPath: ".gemini/settings.json",
            events: ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent", "SessionEnd"],
            inline: true)

        static let all: [Target] = [.claude, .codex, .gemini]
    }

    /// Claude Code's events MyHub listens to.
    static var claudeEvents: [String] { Target.claude.events }
    static var claudeSettings: URL { Target.claude.settings }

    static func endpoint(port: UInt16, agent: String) -> String { "http://127.0.0.1:\(port)/hook/\(agent)" }

    /// The shell command a hook runs.
    /// The permission hook: waits for MyHub's answer and prints it on stdout,
    /// which is how a command hook decides. If MyHub is not running it
    /// prints nothing, and the agent asks the user as usual.
    static func permissionCommand(port: UInt16, agent: String, token: String) -> String {
        "/usr/bin/curl -s -m \(Int(AgentHookServer.permissionWait) + 3) -X POST -H 'Content-Type: application/json' -H 'X-MyHub-Token: \(token)' --data-binary @- http://127.0.0.1:\(port)/permission/\(agent) || true"
    }

    static func command(port: UInt16, agent: String, token: String) -> String {
        "/usr/bin/curl -s -m 2 -o /dev/null -X POST -H 'Content-Type: application/json' -H 'X-MyHub-Token: \(token)' --data-binary @- \(endpoint(port: port, agent: agent)) || true"
    }

    /// Whether `settings` holds a MyHub hook for `agent`.
    static func isInstalled(in settings: [String: Any], agent: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { groups in
            (groups as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { isMine($0, agent: agent) }
            }
        }
    }

    /// `settings` with MyHub's hook for `agent` on every event in `events`
    /// (replacing any older MyHub entry), everything else untouched.
    static func installing(into settings: [String: Any], events: [String], agent: String, port: UInt16, token: String,
                           handler customHandler: [String: Any]? = nil) -> [String: Any] {
        var result = removing(from: settings, agent: agent)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        let handler = customHandler ?? ["type": "command", "command": command(port: port, agent: agent, token: token), "async": true, "timeout": 5]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["matcher": "*", "hooks": [handler]])
            hooks[event] = groups
        }
        result["hooks"] = hooks
        return result
    }

    /// `settings` without MyHub's hook for `agent`. Groups and events left
    /// empty by that are dropped; nothing else changes.
    static func removing(from settings: [String: Any], agent: String) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let others = handlers.filter { !isMine($0, agent: agent) }
                if others.count == handlers.count { return group }
                if others.isEmpty { return nil }
                var copy = group
                copy["hooks"] = others
                return copy
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        var result = settings
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }

    private static func isMine(_ handler: [String: Any], agent: String) -> Bool {
        let text = (handler["command"] as? String ?? "") + (handler["url"] as? String ?? "")
        return text.contains("127.0.0.1:") && text.contains("X-MyHub-Token")
            && (text.contains("/hook/\(agent)") || text.contains("/permission/\(agent)"))
    }

    // MARK: - Files

    static func read(_ file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        guard let data = try? Data(contentsOf: file) else { throw Failure.unreadable }
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notAnObject }
        return object
    }

    /// Writes `settings` back, keeping a one-time backup of the original.
    /// Installs MyHub's hook for `target` in its settings file; with
    /// `approvals`, also the permission hook (Claude Code only).
    static func install(_ target: Target, port: UInt16, token: String, approvals: Bool = false) throws {
        let current = try read(target.settings)
        var updated = installing(into: current, events: target.events, agent: target.id, port: port, token: token,
                                 handler: target.handler(port: port, token: token))
        if approvals, target.id == Target.claude.id {
            updated = addingPermissionHook(to: updated, agent: target.id, port: port, token: token)
        }
        try write(updated, to: target.settings)
    }

    /// The synchronous `PermissionRequest` hook, alongside whatever else is
    /// there. Its timeout leaves the agent time to fall back to its prompt.
    static func addingPermissionHook(to settings: [String: Any], agent: String, port: UInt16, token: String) -> [String: Any] {
        var result = settings
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        var groups = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        groups.append(["matcher": "*", "hooks": [[
            "type": "command",
            "command": permissionCommand(port: port, agent: agent, token: token),
            "timeout": Int(AgentHookServer.permissionWait) + 5,
        ]]])
        hooks["PermissionRequest"] = groups
        result["hooks"] = hooks
        return result
    }

    static func hasPermissionHook(in settings: [String: Any], agent: String) -> Bool {
        ((settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []).contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains("/permission/\(agent)") == true }
        }
    }

    static func uninstall(_ target: Target) throws {
        guard FileManager.default.fileExists(atPath: target.settings.path) else { return }
        try write(removing(from: try read(target.settings), agent: target.id), to: target.settings)
    }

    static func isInstalled(_ target: Target) -> Bool {
        (try? read(target.settings)).map { isInstalled(in: $0, agent: target.id) } ?? false
    }

    static func write(_ settings: [String: Any], to file: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = file.appendingPathExtension("before-myhub")
        if fm.fileExists(atPath: file.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: file, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }
}
