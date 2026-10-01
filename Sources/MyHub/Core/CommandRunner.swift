import Foundation

/// Runs developer command-line tools (`xcrun simctl`, `git`, `shortcuts`)
/// off the main thread.
///
/// Rules that keep it safe and predictable:
/// - an absolute executable path and an argument array — never a shell, so
///   nothing the user typed or a repository contains is ever interpreted;
/// - a fixed `PATH` and a clean environment, so the result doesn't depend on
///   how MyHub was launched;
/// - a deadline, after which the process is terminated;
/// - output capped, so a runaway tool can't fill memory.
enum CommandRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { status == 0 }

        /// What to show the user when the command failed: the first line of
        /// stderr, or the exit status.
        var failureReason: String {
            let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty ? L10n.format("exit status %d", status) : String(line.prefix(160))
        }
    }

    enum Failure: Error, LocalizedError {
        case notInstalled(String)
        case couldNotStart(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let tool): L10n.format("%@ is not installed.", tool)
            case .couldNotStart(let reason): reason
            }
        }
    }

    static let maxOutputBytes = 2 * 1024 * 1024

    static let environment: [String: String] = {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "LANG": "en_US.UTF-8"]
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        // git: never page, never ask for credentials in a terminal we don't have.
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        return env
    }()

    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil,
                    timeout: Duration = .seconds(30)) async throws -> Output {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw Failure.notInstalled((executable as NSString).lastPathComponent)
        }
        // Waiting on a process blocks a thread, so it happens on a Dispatch
        // queue rather than on Swift concurrency's small fixed pool.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try runBlocking(executable, arguments, in: directory, timeout: timeout) })
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], in directory: URL?,
                                    timeout: Duration) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        if let directory { process.currentDirectoryURL = directory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw Failure.couldNotStart(error.localizedDescription)
        }
        let handle = ProcessHandle(process)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { handle.terminate() }
        // Both pipes are drained at once: a tool that fills one while we wait
        // on the other would otherwise block forever.
        let errorBox = DataBox()
        let errorRead = DispatchGroup()
        errorRead.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.data = err.fileHandleForReading.readDataToEndOfFile()
            errorRead.leave()
        }
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errorRead.wait()
        return Output(status: process.terminationStatus,
                      stdout: String(decoding: outputData.prefix(maxOutputBytes), as: UTF8.self),
                      stderr: String(decoding: errorBox.data.prefix(64 * 1024), as: UTF8.self))
    }

    /// Whether Xcode or the Command Line Tools are installed. Asked through
    /// `xcode-select -p`, which, unlike `/usr/bin/git` itself, never pops up
    /// the "install developer tools" dialog.
    static func developerToolsInstalled() async -> Bool {
        (try? await run("/usr/bin/xcode-select", ["-p"], timeout: .seconds(5)))?.succeeded ?? false
    }
}

/// `Process` is not Sendable; the deadline only ever calls `terminate`
/// (after checking `isRunning`), both safe from any thread.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}

/// Written once by the reader before it leaves the group, read only after
/// the group is waited on; the group orders the two.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
