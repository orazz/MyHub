import Foundation
import Testing
@testable import MyHub

@Suite struct AgentEventTests {
    func event(_ json: String) -> AgentEvent? { AgentEvent.parse(Data(json.utf8), agent: "claude") }

    @Test func toolCallsBecomeReadableSteps() throws {
        let read = try #require(event(#"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/Users/me/Code/Orbit","tool_name":"Read","tool_input":{"file_path":"/Users/me/Code/Orbit/App.swift"}}"#))
        #expect(read.project == "Orbit")
        #expect(read.kind == .toolStarted(AgentStep(tool: "Read", action: .read, detail: "App.swift")))
        let bash = try #require(event(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"swift test\nmore"}}"#))
        guard case .toolStarted(let step) = bash.kind else { Issue.record("not a tool"); return }
        #expect(step.summary == "Run swift test")
        let edit = AgentStep(tool: "MultiEdit", input: ["file_path": "/a/b/Model.swift"])
        #expect(edit.action == .edit && edit.detail == "Model.swift")
        #expect(AgentStep(tool: "mcp__github__create_issue", input: [:]).action == .other)
    }

    @Test func lifecycleEventsMap() {
        #expect(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"Fix the login bug\nplease"}"#)?.kind == .prompt("Fix the login bug"))
        #expect(event(#"{"hook_event_name":"Stop","session_id":"s"}"#)?.kind == .finished)
        #expect(event(#"{"hook_event_name":"Notification","session_id":"s","message":"Claude needs your permission to use Bash"}"#)?.kind
                == .needsAttention("Claude needs your permission to use Bash"))
        #expect(event(#"{"hook_event_name":"PostToolUseFailure","session_id":"s","tool_name":"Bash"}"#)?.kind == .toolFinished(tool: "Bash", succeeded: false))
        #expect(event(#"{"hook_event_name":"SessionEnd","session_id":"s"}"#)?.kind == .sessionEnded)
    }

    @Test func junkIsIgnoredAndLongTextIsCut() {
        #expect(event("not json") == nil)
        #expect(event(#"{"hook_event_name":"Stop"}"#) == nil)                    // no session
        #expect(event(#"{"hook_event_name":"Mystery","session_id":"s"}"#) == nil)
        let long = String(repeating: "x", count: 1000)
        guard case .prompt(let text)? = event(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"\#(long)"}"#)?.kind else {
            Issue.record("no prompt"); return
        }
        #expect(text.count == AgentEvent.maxText)
        #expect(AgentEvent.isValidAgentName("claude") && !AgentEvent.isValidAgentName("../x") && !AgentEvent.isValidAgentName("Claude"))
    }
}

@Suite struct HTTPRequestTests {
    @Test func parsesASmallPost() {
        let raw = "POST /hook/claude?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nX-MyHub-Token: abc\r\nContent-Length: 2\r\n\r\n{}"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8), maxBody: 100) else { Issue.record("not parsed"); return }
        #expect(request.method == "POST" && request.path == "/hook/claude")
        #expect(request.headers["x-myhub-token"] == "abc")
        #expect(request.body == Data("{}".utf8))
    }

    @Test func waitsForTheRestAndRefusesWhatItCantHandle() {
        #expect(HTTPRequest.parse(Data("POST /hook/claude HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8), maxBody: 100) == .incomplete)
        #expect(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Le".utf8), maxBody: 100) == .incomplete)
        #expect(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8), maxBody: 100) == .invalid)
        #expect(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 999\r\n\r\n".utf8), maxBody: 100) == .invalid)
        #expect(AgentHookServer.matches("abc", "abc") && !AgentHookServer.matches("abd", "abc") && !AgentHookServer.matches(nil, "abc"))
    }
}

@Suite struct AgentHookInstallerTests {
    let existing: [String: Any] = [
        "model": "opus",
        "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "~/guard.sh"]]]]],
    ]

    @Test func installKeepsEverythingElseAndIsIdempotent() throws {
        let once = AgentHookInstaller.installing(into: existing, events: ["PreToolUse", "Stop"], agent: "claude", port: 47391, token: "T")
        let twice = AgentHookInstaller.installing(into: once, events: ["PreToolUse", "Stop"], agent: "claude", port: 47391, token: "T")
        #expect(NSDictionary(dictionary: once).isEqual(to: twice))
        #expect(once["model"] as? String == "opus")
        let pre = try #require((once["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 2)                                            // the user's guard + MyHub
        #expect(AgentHookInstaller.isInstalled(in: once, agent: "claude"))
        let mine = try #require((pre.last?["hooks"] as? [[String: Any]])?.first)
        #expect(mine["async"] as? Bool == true)
        #expect((mine["command"] as? String)?.contains("X-MyHub-Token: T") == true)
        #expect((mine["command"] as? String)?.hasSuffix("|| true") == true)
    }

    @Test func removeTakesOutOnlyMyHub() {
        let installed = AgentHookInstaller.installing(into: existing, events: ["PreToolUse", "Stop"], agent: "claude", port: 47391, token: "T")
        let removed = AgentHookInstaller.removing(from: installed, agent: "claude")
        #expect(NSDictionary(dictionary: removed).isEqual(to: existing))
        #expect(!AgentHookInstaller.isInstalled(in: removed, agent: "claude"))
        #expect(AgentHookInstaller.removing(from: [:], agent: "claude").isEmpty)
    }

    @Test func filesAreBackedUpAndBrokenOnesLeftAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubHooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("settings.json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: file)
        try AgentHookInstaller.write(AgentHookInstaller.installing(into: try AgentHookInstaller.read(file), events: ["Stop"],
                                                                   agent: "claude", port: 1, token: "T"), to: file)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("before-myhub").path))
        try Data("{ broken".utf8).write(to: file)
        #expect(throws: AgentHookInstaller.Failure.notAnObject) { try AgentHookInstaller.read(file) }
    }
}

@MainActor
@Suite struct AgentStoreTests {
    func store() throws -> AgentStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubAgents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return AgentStore(preferences: Preferences(file: folder.appendingPathComponent("prefs.json")))
    }

    func send(_ store: AgentStore, _ json: String) { store.receive(agent: "claude", body: Data(json.utf8)) }

    @Test func aTurnGoesFromWorkingToDoneAndFlashesOnce() throws {
        let store = try store()
        var finished = 0
        store.onFinished = { _ in finished += 1 }
        send(store, #"{"hook_event_name":"UserPromptSubmit","session_id":"a","cwd":"/x/Orbit","prompt":"Fix it"}"#)
        send(store, #"{"hook_event_name":"PreToolUse","session_id":"a","tool_name":"Edit","tool_input":{"file_path":"/x/Orbit/A.swift"}}"#)
        #expect(store.working.count == 1)
        #expect(store.sessions[0].stateText == "Edit A.swift")
        send(store, #"{"hook_event_name":"PostToolUse","session_id":"a","tool_name":"Edit"}"#)
        #expect(store.sessions[0].steps[0].succeeded == true)
        send(store, #"{"hook_event_name":"Stop","session_id":"a"}"#)
        send(store, #"{"hook_event_name":"Stop","session_id":"a"}"#)
        #expect(store.sessions[0].state == .done)
        #expect(finished == 1)
        #expect(store.sessions[0].project == "Orbit")
    }

    @Test func waitingAndForgetting() throws {
        let store = try store()
        send(store, #"{"hook_event_name":"Notification","session_id":"b","message":"Claude is waiting for your input"}"#)
        #expect(store.needingAttention.count == 1)
        send(store, #"{"hook_event_name":"SessionEnd","session_id":"b"}"#)
        store.sweep(now: Date().addingTimeInterval(120))
        #expect(store.sessions.isEmpty)
    }
}

@Suite struct AgentHookEndToEndTests {
    /// The exact command written into Claude Code's settings, fed a sample
    /// event, reaches a running receiver — and the wrong token doesn't.
    @Test func theInstalledCommandDeliversEvents() async throws {
        let received = Received()
        let server = AgentHookServer(token: "secret") { agent, body in received.add(agent, body) }
        // A random high port, retried if something else holds it.
        var port: UInt16 = 0
        for _ in 0..<10 {
            let candidate = UInt16.random(in: 49_200...60_000)
            if (try? await server.start(port: candidate)) != nil { port = candidate; break }
        }
        try #require(port != 0)
        defer { server.stop() }
        let json = #"{"hook_event_name":"Stop","session_id":"e2e"}"#
        for token in ["secret", "wrong"] {
            let command = AgentHookInstaller.command(port: port, agent: "claude", token: token)
            let out = try await CommandRunner.run("/bin/sh", ["-c", "printf '%s' '\(json)' | \(command)"], timeout: .seconds(10))
            #expect(out.succeeded)                                      // never fails the agent's hook
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(received.items.count == 1)
        #expect(received.items.first?.0 == "claude")
        #expect(received.items.first.map { String(decoding: $0.1, as: UTF8.self) } == json)
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(String, Data)] = []
    func add(_ agent: String, _ body: Data) { lock.lock(); stored.append((agent, body)); lock.unlock() }
    var items: [(String, Data)] { lock.lock(); defer { lock.unlock() }; return stored }
}

@Suite struct OtherAgentsTests {
    @Test func geminiEventsMap() throws {
        func gemini(_ json: String) -> AgentEvent? { AgentEvent.parse(Data(json.utf8), agent: "gemini") }
        let tool = try #require(gemini(#"{"hook_event_name":"BeforeTool","session_id":"g","cwd":"/x/docs","tool_name":"run_shell_command","tool_input":{"command":"npm test"}}"#))
        #expect(tool.kind == .toolStarted(AgentStep(tool: "run_shell_command", action: .run, detail: "npm test")))
        #expect(gemini(#"{"hook_event_name":"BeforeAgent","session_id":"g","prompt":"Write docs"}"#)?.kind == .prompt("Write docs"))
        #expect(gemini(#"{"hook_event_name":"AfterAgent","session_id":"g"}"#)?.kind == .finished)
        #expect(gemini(#"{"hook_event_name":"Notification","session_id":"g","notification_type":"ToolPermission","message":"Allow npm publish?"}"#)?.kind
                == .needsAttention("Allow npm publish?"))
    }

    @Test func codexPatchesNameTheirFile() {
        let step = AgentStep(tool: "apply_patch", input: ["input": "*** Begin Patch\n*** Update File: Sources/App/Login.swift\n@@\n-old\n+new\n*** End Patch"])
        #expect(step.action == .edit && step.detail == "Login.swift")
        #expect(AgentEvent.parse(Data(#"{"hook_event_name":"PermissionRequest","session_id":"c"}"#.utf8), agent: "codex")?.kind
                == .needsAttention("Asking for permission"))
    }

    @Test func eachAgentGetsItsOwnHookShape() throws {
        let codex = AgentHookInstaller.Target.codex.handler(port: 47391, token: "T")
        #expect(codex["async"] as? Bool == true && codex["timeout"] as? Int == 5)
        let gemini = AgentHookInstaller.Target.gemini.handler(port: 47391, token: "T")
        #expect(gemini["async"] == nil)
        #expect(gemini["timeout"] as? Int == 3000)                       // milliseconds for Gemini
        #expect((gemini["command"] as? String)?.hasSuffix("printf '{}'") == true)
        #expect((gemini["command"] as? String)?.contains("/hook/gemini") == true)
        let settings = AgentHookInstaller.installing(into: ["general": ["vimMode": true]], events: ["BeforeTool"], agent: "gemini",
                                                     port: 47391, token: "T", handler: gemini)
        #expect(AgentHookInstaller.isInstalled(in: settings, agent: "gemini"))
        #expect(!AgentHookInstaller.isInstalled(in: settings, agent: "claude"))
        #expect((settings["general"] as? [String: Bool])?["vimMode"] == true)
    }

    /// Gemini reads the hook's stdout as JSON: the command must print `{}`
    /// and nothing else, whether MyHub is listening or not.
    @Test func geminiHookPrintsOnlyJSON() async throws {
        let command = try #require(AgentHookInstaller.Target.gemini.handler(port: 1, token: "T")["command"] as? String)
        let out = try await CommandRunner.run("/bin/sh", ["-c", "printf '{}' | \(command)"], timeout: .seconds(10))
        #expect(out.succeeded)
        #expect(out.stdout == "{}")
    }
}

@Suite struct ApprovalTests {
    @Test func repliesAreTheJSONClaudeCodeExpects() throws {
        for (reply, behavior) in [(ApprovalReply.allow, "allow"), (.deny, "deny")] {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.json.utf8)) as? [String: Any])
            let output = try #require(object["hookSpecificOutput"] as? [String: Any])
            #expect(output["hookEventName"] as? String == "PermissionRequest")
            #expect((output["decision"] as? [String: Any])?["behavior"] as? String == behavior)
        }
        #expect(ApprovalReply.askInTerminal.json == "{}")
    }

    @Test func requestsDescribeTheTool() throws {
        let body = #"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/x/Orbit","tool_name":"Bash","tool_input":{"command":"npm run deploy"}}"#
        let approval = try #require(AgentApproval.parse(Data(body.utf8), agent: "claude", now: Date(timeIntervalSince1970: 0), wait: 55))
        #expect(approval.step.summary == "Run npm run deploy")
        #expect(approval.project == "Orbit")
        #expect(approval.deadline == Date(timeIntervalSince1970: 54))
        #expect(AgentApproval.parse(Data("{}".utf8), agent: "claude") == nil)
    }

    @Test func thePermissionHookIsOptInAndRemovable() {
        let base = AgentHookInstaller.installing(into: [:], events: ["Stop"], agent: "claude", port: 47391, token: "T")
        #expect(!AgentHookInstaller.hasPermissionHook(in: base, agent: "claude"))
        let withApprovals = AgentHookInstaller.addingPermissionHook(to: base, agent: "claude", port: 47391, token: "T")
        #expect(AgentHookInstaller.hasPermissionHook(in: withApprovals, agent: "claude"))
        let handler = (((withApprovals["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        #expect(handler?["async"] == nil)                                // must wait for the answer
        #expect((handler?["timeout"] as? Int ?? 0) > Int(AgentHookServer.permissionWait))
        #expect(!((handler?["command"] as? String)?.contains("-o /dev/null") ?? true))   // stdout carries the decision
        let removed = AgentHookInstaller.removing(from: withApprovals, agent: "claude")
        #expect(removed.isEmpty)
    }

    @Test func anAnswerGoesOutOnce() {
        let sent = Received()
        let answer = PermissionAnswer { json in sent.add("x", Data(json.utf8)) }
        #expect(answer.send(ApprovalReply.allow.json))
        #expect(!answer.send(ApprovalReply.deny.json))
        #expect(sent.items.count == 1)
    }

    @MainActor
    @Test func withApprovalsOffRequestsGoStraightBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubApprovals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = AgentStore(preferences: Preferences(file: folder.appendingPathComponent("prefs.json")))
        let sent = Received()
        let body = Data(#"{"session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
        store.receivePermission(agent: "claude", body: body, answer: PermissionAnswer { sent.add("x", Data($0.utf8)) })
        #expect(store.approvals.isEmpty)
        #expect(sent.items.first.map { String(decoding: $0.1, as: UTF8.self) } == "{}")
    }

    /// The installed permission command waits for MyHub's answer and prints
    /// it; with MyHub not running it prints nothing and still succeeds.
    @Test func thePermissionCommandRelaysTheDecision() async throws {
        let server = AgentHookServer(token: "secret", onEvent: { _, _ in }, onPermission: { _, _, answer in
            answer.send(ApprovalReply.allow.json)
        })
        var port: UInt16 = 0
        for _ in 0..<10 {
            let candidate = UInt16.random(in: 49_200...60_000)
            if (try? await server.start(port: candidate)) != nil { port = candidate; break }
        }
        try #require(port != 0)
        defer { server.stop() }
        let json = #"{"session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        let command = AgentHookInstaller.permissionCommand(port: port, agent: "claude", token: "secret")
        let answered = try await CommandRunner.run("/bin/sh", ["-c", "printf '%s' '\(json)' | \(command)"], timeout: .seconds(15))
        #expect(answered.stdout == ApprovalReply.allow.json)
        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        let offline = try await CommandRunner.run("/bin/sh", ["-c", "printf '%s' '\(json)' | \(command)"], timeout: .seconds(15))
        #expect(offline.succeeded && offline.stdout.isEmpty)
    }
}

@Suite struct ClaudeCodeLauncherTests {
    /// Runs the generated script's quoting through a real shell: a hostile
    /// question and path must come out as literal text, never as commands.
    @Test func questionsAndPathsAreNeverInterpreted() async throws {
        let hostile = "What's this? $(touch /tmp/myhub-pwned) `id` ; rm -rf ~ \"quoted\" \\ end"
        let file = URL(fileURLWithPath: "/tmp/it's a \"file\" $HOME.pdf")
        let echoed = try await CommandRunner.run("/bin/zsh", ["-c", "printf '%s' \(ClaudeCodeLauncher.quoted(ClaudeCodeLauncher.prompt(question: hostile, files: [file])))"])
        #expect(echoed.stdout == ClaudeCodeLauncher.prompt(question: hostile, files: [file]))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/myhub-pwned"))
    }

    @Test func theScriptCleansUpAndStartsClaudeInTheFilesFolder() {
        let file = URL(fileURLWithPath: "/Users/me/Downloads/Invoice.pdf")
        let script = ClaudeCodeLauncher.script(question: "", files: [file])
        #expect(script.hasPrefix("#!/bin/zsh -l\nrm -f -- \"$0\""))
        #expect(script.contains("cd -- '/Users/me/Downloads'"))
        #expect(script.contains("exec claude " + ClaudeCodeLauncher.quoted(ClaudeCodeLauncher.prompt(question: "", files: [file]))))
        #expect(ClaudeCodeLauncher.prompt(question: "", files: [file]).hasPrefix(ClaudeCodeLauncher.defaultQuestion))
        #expect(script.contains("File: /Users/me/Downloads/Invoice.pdf"))
    }

    @Test func scriptsThatNeverRanAreClearedLater() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyHubAsk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stale = folder.appendingPathComponent("Ask Claude old.command"), fresh = folder.appendingPathComponent("Ask Claude new.command")
        let other = folder.appendingPathComponent("keep.txt")
        for url in [stale, fresh, other] { try Data().write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: other.path)
        ClaudeCodeLauncher.removeLeftovers(in: folder)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func severalFilesAreListedAndAFolderIsItsOwnWorkingFolder() {
        let files = [URL(fileURLWithPath: "/Users/me/Code/Orbit/", isDirectory: true), URL(fileURLWithPath: "/Users/me/Desktop/notes.md")]
        #expect(ClaudeCodeLauncher.prompt(question: " Compare these ", files: files)
            == "Compare these\n\nFiles:\n- /Users/me/Code/Orbit\n- /Users/me/Desktop/notes.md")
        #expect(ClaudeCodeLauncher.workingFolder(for: files)?.path == "/Users/me/Code/Orbit")
        #expect(ClaudeCodeLauncher.workingFolder(for: []) == nil)
    }
}

@Suite struct AskTargetTests {
    let file = URL(fileURLWithPath: "/Users/me/Orbit Docs/Q3 plan & notes+v2.md")

    func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func claudeCodeLinkCarriesFolderAndPromptIntact() throws {
        let question = "What's due? a=1&b=2 + 50% #tag"
        let link = try #require(AskTarget.claudeCodeLink(question: question, files: [file]))
        #expect(link.absoluteString.hasPrefix("claude-cli://open?cwd=%2FUsers%2Fme%2FOrbit%20Docs&q="))
        // Every reserved character is encoded, so nothing splits the query.
        #expect(!link.query!.contains("+") && link.query!.components(separatedBy: "&").count == 2)
        let fields = query(link)
        #expect(fields["cwd"] == "/Users/me/Orbit Docs")
        #expect(fields["q"] == ClaudeCodeLauncher.prompt(question: question, files: [file]))
    }

    @Test func claudeCodePromptIsCappedAtItsLimit() throws {
        let link = try #require(AskTarget.claudeCodeLink(question: String(repeating: "x", count: 9000), files: [file]))
        #expect(query(link)["q"]?.count == AskTarget.claudeCodeQuestionLimit)
    }

    @Test func codexLinkOpensANewChatInTheFolder() throws {
        let link = try #require(AskTarget.codexLink(question: "", files: [file]))
        #expect(link.scheme == "codex" && link.host == "new")
        #expect(query(link)["path"] == "/Users/me/Orbit Docs")
        #expect(query(link)["prompt"]?.hasPrefix(ClaudeCodeLauncher.defaultQuestion) == true)
        #expect(AskTarget.codexLink(question: "", files: []) == nil)
    }

    @Test func onlyTheTerminalAppsTakeTheQuestionDirectly() {
        #expect(AskTarget.allCases.filter(\.takesQuestion) == [.claudeCode, .codex])
    }
}
