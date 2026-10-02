import AppKit

/// Where "Ask AI" sends stashed files. Every route uses the app's own,
/// documented way in, with the user's own install and sign-in; MyHub never
/// calls a model and never sends anything itself.
enum AskTarget: String, CaseIterable, Sendable {
    /// `claude-cli://open?cwd=…&q=…` (Claude Code's deep link handler): the
    /// user's preferred terminal, prompt filled in but not sent. Falls back
    /// to `ClaudeCodeLauncher` when only the CLI is installed.
    case claudeCode
    /// `codex://new?path=…&prompt=…`: a new chat in the file's folder, the
    /// question in the composer.
    case codex
    /// The Claude app opens files and folders (its Info.plist says so).
    case claudeApp
    /// The ChatGPT app, when macOS lists it as able to open the files.
    case chatGPT

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .claudeApp: "Claude"
        case .chatGPT: "ChatGPT"
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode, .codex: "terminal"
        case .claudeApp, .chatGPT: "bubble.left.and.text.bubble.right"
        }
    }

    /// The question goes into the app's prompt box. Otherwise the files are
    /// handed over and the question is put on the clipboard to paste.
    var takesQuestion: Bool { self == .claudeCode || self == .codex }

    static let claudeAppID = "com.anthropic.claudefordesktop"
    static let chatGPTID = "com.openai.chat"

    // MARK: - Links

    /// Claude Code caps `q` at 5,000 characters.
    static let claudeCodeQuestionLimit = 5000

    static func claudeCodeLink(question: String, files: [URL]) -> URL? {
        guard let folder = ClaudeCodeLauncher.workingFolder(for: files) else { return nil }
        let prompt = String(ClaudeCodeLauncher.prompt(question: question, files: files).prefix(claudeCodeQuestionLimit))
        return link("claude-cli://open", ["cwd": folder.path, "q": prompt])
    }

    static func codexLink(question: String, files: [URL]) -> URL? {
        guard let folder = ClaudeCodeLauncher.workingFolder(for: files) else { return nil }
        return link("codex://new", ["path": folder.path, "prompt": ClaudeCodeLauncher.prompt(question: question, files: files)])
    }

    /// Only letters, digits and `-._~` stay as they are; everything else,
    /// `&`, `=`, `+` and `/` included, is percent-encoded.
    static func link(_ base: String, _ query: KeyValuePairs<String, String>) -> URL? {
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = query.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
        }
        return URL(string: base + "?" + encoded.joined(separator: "&"))
    }

    // MARK: - Availability

    /// The targets this Mac can use for `files`, in menu order.
    @MainActor
    static func available(for files: [URL]) -> [AskTarget] {
        allCases.filter { $0.isAvailable(for: files) }
    }

    @MainActor
    func isAvailable(for files: [URL]) -> Bool {
        let workspace = NSWorkspace.shared
        switch self {
        case .claudeCode:
            return Self.handles("claude-cli://open") || ClaudeCodeLauncher.isInstalled
        case .codex:
            return Self.handles("codex://new")
        case .claudeApp, .chatGPT:
            guard let app = workspace.urlForApplication(withBundleIdentifier: self == .claudeApp ? Self.claudeAppID : Self.chatGPTID),
                  !files.isEmpty else { return false }
            // The app itself says it can open each of these files.
            return files.allSatisfy { file in workspace.urlsForApplications(toOpen: file).contains { $0.standardizedFileURL == app.standardizedFileURL } }
        }
    }

    /// Any of the apps or the CLI is on this Mac, whatever the files.
    @MainActor
    static var anyInstalled: Bool {
        ClaudeCodeLauncher.isInstalled || handles("claude-cli://open") || handles("codex://new")
            || [claudeAppID, chatGPTID].contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    private static func handles(_ link: String) -> Bool {
        URL(string: link).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
    }

    // MARK: - Asking

    @MainActor
    func ask(_ question: String, about files: [URL]) throws {
        let workspace = NSWorkspace.shared
        switch self {
        case .claudeCode:
            if Self.handles("claude-cli://open"), let link = Self.claudeCodeLink(question: question, files: files) {
                workspace.open(link)
            } else {
                try ClaudeCodeLauncher.ask(question, about: files)
            }
        case .codex:
            guard let link = Self.codexLink(question: question, files: files) else { return }
            workspace.open(link)
        case .claudeApp, .chatGPT:
            guard let app = workspace.urlForApplication(withBundleIdentifier: self == .claudeApp ? Self.claudeAppID : Self.chatGPTID) else {
                throw ClaudeCodeLauncher.Failure.notInstalled
            }
            let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(trimmed, forType: .string)
            }
            workspace.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
