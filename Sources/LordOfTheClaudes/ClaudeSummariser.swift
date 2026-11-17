import Darwin
import Foundation
import LotcKit

/// The summariser that runs `claude -p` with Haiku, on the user's own Claude Code login.
struct ClaudeSummariser: Summariser {
    enum Failure: Error, CustomStringConvertible {
        case noClaude
        case unreadable(String)

        var description: String {
            switch self {
            case .noClaude: return "found no claude to run"
            case .unreadable(let output): return "claude -p said: \(output.prefix(300))"
            }
        }
    }

    /// Where every summariser run starts, so the poll can tell those sessions from the user's own.
    static let workingDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("LordOfTheClaudes-observer")
    /// Symlinks resolve only in a path that exists, and Claude's registry has the resolved one.
    private static let resolvedWorkingDirectory: String = {
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        return workingDirectory.resolvingSymlinksInPath().path
    }()

    /// A summariser run is a Claude Code session in Claude's own registry; it is never one of the user's.
    static func isOwnRun(cwd: String) -> Bool {
        cwd.hasSuffix(workingDirectory.lastPathComponent)
            && URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == resolvedWorkingDirectory
    }

    /// No tools, no saved session, nothing from the user's set-up but the login: safe mode leaves out hooks,
    /// MCP servers, skills, plugins and CLAUDE.md, and the settings turn hooks off again in case it ever does not.
    static func arguments() -> [String] {
        ["-p", "--model", "haiku", "--output-format", "json", "--no-session-persistence", "--safe-mode",
         "--tools", "", "--settings", #"{"disableAllHooks":true}"#, "--system-prompt", DigestReply.instructions]
    }

    func summarise(_ excerpt: String) async throws -> String {
        guard let claude = ClaudeLocator.shared.path() else { throw Failure.noClaude }
        try? FileManager.default.createDirectory(at: Self.workingDirectory, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment[ObserverRun.variable] = "1"
        let directory = (claude as NSString).deletingLastPathComponent
        environment["PATH"] = ([directory] + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init))
            .joined(separator: ":")
        let output = try await ChildProcess.run(
            URL(fileURLWithPath: claude), arguments: Self.arguments(), environment: environment,
            directory: Self.workingDirectory, input: Data(excerpt.utf8))
        guard let reply = DigestReply.result(fromJSON: output) else {
            throw Failure.unreadable(String(decoding: output, as: UTF8.self))
        }
        return reply
    }
}

/// Runs a program to the end with stdin given and stdout collected. Cancelling the task ends the program.
enum ChildProcess {
    static func run(_ executable: URL, arguments: [String], environment: [String: String], directory: URL,
                    input: Data) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let handle = Unchecked(process)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                    let output = stdout.fileHandleForReading.readDataToEndOfFile()
                    handle.value.waitUntilExit()
                    continuation.resume(returning: output)
                }
            }
        } onCancel: {
            let process = handle.value
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { kill(pid, SIGKILL) } }
        }
    }
}

/// Process is safe to use from the threads here: they only wait on it and stop it.
private final class Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Finds `claude`. Opened from Finder the app has a bare PATH, so it also looks where installers put it
/// and on the PATH of the user's login shell.
final class ClaudeLocator: @unchecked Sendable {
    static let shared = ClaudeLocator()

    /// Where Claude Code's installers and the package managers put it, `~` for the home directory.
    static let usualPlaces = [
        "~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
        "~/.npm-global/bin", "~/.bun/bin", "~/.volta/bin", "~/bin",
    ]

    private let lock = NSLock()
    private var found: String?

    /// Found once, looked for again if it goes missing.
    func path() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let found, FileManager.default.isExecutableFile(atPath: found) { return found }
        let environment = ProcessInfo.processInfo.environment
        found = Self.find(
            path: environment["PATH"], home: NSHomeDirectory(),
            isExecutable: FileManager.default.isExecutableFile(atPath:),
            loginShellPath: { Self.loginShellPath(shell: environment["SHELL"] ?? "/bin/zsh") })
        return found
    }

    /// The first `claude` on `path`, then in the usual places, then on the login shell's PATH, asked only if need be.
    static func find(path: String?, home: String, isExecutable: (String) -> Bool,
                     loginShellPath: () -> String?) -> String? {
        func first(in directories: [String]) -> String? {
            directories.lazy
                .map { ($0.hasPrefix("~/") ? home + $0.dropFirst() : $0) + "/claude" }
                .first(where: isExecutable)
        }
        func split(_ path: String?) -> [String] { (path ?? "").split(separator: ":").map(String.init) }
        return first(in: split(path)) ?? first(in: usualPlaces) ?? first(in: split(loginShellPath()))
    }

    static let pathMarker = "LOTC_PATH="

    /// The PATH an interactive login shell sets up, which is where a terminal user's `claude` is found.
    static func loginShellPath(shell: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", #"printf '\n\#(pathMarker)%s\n' "$PATH""#]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // A shell profile can wait on anything; never on it for long.
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(pid, SIGKILL) } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return path(inShellOutput: String(decoding: data, as: UTF8.self))
    }

    /// The marked line, whatever else the shell's profile printed around it.
    static func path(inShellOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline).last { $0.hasPrefix(pathMarker) }
            .map { String($0.dropFirst(pathMarker.count)) }
    }
}
