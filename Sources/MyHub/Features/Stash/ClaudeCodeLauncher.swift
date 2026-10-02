import AppKit

/// Starts Claude Code — the user's own install, signed in with their own
/// account — in their terminal, with a question about a file.
///
/// MyHub never talks to a model itself. It writes a one-time `.command`
/// script, which macOS opens in the default terminal app (Terminal, iTerm…),
/// so no Apple Events permission is needed. The script deletes itself as it
/// starts, changes into the first file's folder and runs `claude` with the
/// question and the files' paths as its first prompt.
enum ClaudeCodeLauncher {
    enum Failure: Error, Equatable {
        case notInstalled
        case couldNotWrite
    }

    static let defaultQuestion = "Take a look at this and tell me what's in it."

    /// The first prompt: the question, then where the files are.
    static func prompt(question: String, files: [URL]) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = files.count == 1 ? "File: \(files[0].path)" : "Files:\n" + files.map { "- \($0.path)" }.joined(separator: "\n")
        return "\(trimmed.isEmpty ? defaultQuestion : trimmed)\n\n\(list)"
    }

    /// Where Claude Code starts: the folder itself, or the first file's folder.
    static func workingFolder(for files: [URL]) -> URL? {
        guard let first = files.first else { return nil }
        return first.hasDirectoryPath ? first : first.deletingLastPathComponent()
    }

    /// The shell script. Every value is single-quoted, with embedded quotes
    /// closed and escaped, so nothing in a path or question is interpreted
    /// by the shell.
    static func script(question: String, files: [URL]) -> String {
        let folder = workingFolder(for: files)?.path ?? NSHomeDirectory()
        return """
        #!/bin/zsh -l
        rm -f -- "$0"
        cd -- \(quoted(folder)) || exit 1
        if ! command -v claude >/dev/null 2>&1; then
          echo "Claude Code isn't installed (https://code.claude.com)."
          exit 1
        fi
        exec claude \(quoted(prompt(question: question, files: files)))

        """
    }

    /// `'…'` with any `'` inside written as `'\''`.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether `claude` is on this Mac, where installers usually put it.
    static var isInstalled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude",
                "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Writes the script (owner-only, in a private temporary folder) and
    /// opens it in the default terminal.
    @MainActor
    static func ask(_ question: String, about files: [URL]) throws {
        guard isInstalled else { throw Failure.notInstalled }
        guard !files.isEmpty else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyHub-claude", isDirectory: true)
        let url = folder.appendingPathComponent("Ask Claude \(UUID().uuidString.prefix(8)).command")
        removeLeftovers(in: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(script(question: question, files: files).utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw Failure.couldNotWrite
        }
        NSWorkspace.shared.open(url)
    }

    /// A script deletes itself as it starts. One still here after ten minutes
    /// never ran: the shell lost the typed path (a startup prompt such as
    /// oh-my-zsh's "update?" can swallow its first character).
    static func removeLeftovers(in folder: URL, olderThan age: TimeInterval = 600, now: Date = Date()) {
        let fm = FileManager.default
        let scripts = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for script in scripts where script.pathExtension == "command" {
            let modified = (try? script.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > age { try? fm.removeItem(at: script) }
        }
    }
}
