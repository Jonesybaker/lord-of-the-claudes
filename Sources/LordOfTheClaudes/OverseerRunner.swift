import Darwin
import Foundation

/// One turn of the overseer's conversation, as handed to Claude Code.
struct OverseerRequest: Equatable, Sendable {
    /// The user's words with the briefing in front, sent on stdin.
    let message: String
    let systemPrompt: String
    /// Claude Code's id for the conversation.
    let sessionId: String
    /// Carry on the conversation with this id rather than start it.
    let resume: Bool
    let settings: OverseerSettings
}

enum OverseerEvent: Equatable, Sendable {
    /// The reply so far, while it streams in.
    case partial(String)
    /// The whole reply. Always the last event.
    case answer(String)
}

enum OverseerFailure: Error, Equatable {
    case noClaude
    /// The conversation to resume is not on disk any more.
    case conversationGone
    case failed(String)
}

/// Runs a turn of the overseer. The app's runs `claude -p`; tests fake it.
protocol OverseerRunning: Sendable {
    func run(_ request: OverseerRequest) -> AsyncThrowingStream<OverseerEvent, Error>
}

/// The overseer is a headless Claude Code conversation on the user's own login: `claude -p`, resumed
/// each turn, with no tools, no hooks, no MCP servers and no CLAUDE.md (`--safe-mode`).
struct ClaudeCLI: OverseerRunning {
    static let timeout: TimeInterval = 180

    static func arguments(for request: OverseerRequest) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--model", request.settings.model, "--safe-mode", "--tools", "", "--disable-slash-commands",
                    "--system-prompt", request.systemPrompt]
        args += request.resume ? ["--resume", request.sessionId] : ["--session-id", request.sessionId]
        if let effort = request.settings.effort { args += ["--effort", effort] }
        return args
    }

    func run(_ request: OverseerRequest) -> AsyncThrowingStream<OverseerEvent, Error> {
        AsyncThrowingStream { continuation in
            let box = ProcessBox()
            continuation.onTermination = { _ in box.stop() }
            Task.detached {
                do {
                    try await Self.drive(request, box: box) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func drive(_ request: OverseerRequest, box: ProcessBox,
                              yield: @escaping (OverseerEvent) -> Void) async throws {
        guard let claude = ClaudeBinary.locate(override: request.settings.claude) else { throw OverseerFailure.noClaude }
        try? FileManager.default.createDirectory(at: OverseerFiles.workspace, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments(for: request)
        process.currentDirectoryURL = OverseerFiles.workspace
        process.environment = environment(claude: claude)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        guard box.start(process) else {
            throw box.stopped ? CancellationError() : OverseerFailure.failed("Could not start \(claude).")
        }
        let errors = Task.detached { String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
        // A process that has already died would otherwise kill the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? stdin.fileHandleForWriting.write(contentsOf: Data(request.message.utf8))
        try? stdin.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.stop(timedOut: true) }

        var streamed = ""
        var final: String?
        var failure: OverseerFailure?
        for try await line in stdout.fileHandleForReading.bytes.lines {
            switch StreamLine.parse(line) {
            case .textDelta(let text):
                streamed += text
                yield(.partial(streamed))
            case .message(let text):
                if streamed.isEmpty { final = text }
            case .result(let text, let isError, let messages):
                if isError {
                    let message = messages.joined(separator: " ").trimmedNonEmpty ?? text.trimmedNonEmpty ?? "Claude Code stopped with an error."
                    failure = message.contains("No conversation found") ? .conversationGone : .failed(message)
                } else {
                    final = text.isEmpty ? (final ?? streamed) : text
                }
            case .other:
                break
            }
        }
        process.waitUntilExit()
        let errorText = await errors.value
        if let failure { throw failure }
        if box.timedOut { throw OverseerFailure.failed("No answer after \(Int(timeout)) seconds.") }
        if Task.isCancelled || box.stopped { throw CancellationError() }
        guard let final else {
            let lastLines = errorText.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
            if lastLines.contains("No conversation found") { throw OverseerFailure.conversationGone }
            throw OverseerFailure.failed(lastLines.trimmedNonEmpty ?? "Claude Code exited with status \(process.terminationStatus).")
        }
        yield(.answer(final))
    }

    /// The app may have been opened from Finder with a bare PATH. LOTC_OBSERVER=1 turns lotc's hooks off for this run.
    private static func environment(claude: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: claude).deletingLastPathComponent().path
        env["PATH"] = [dir, env["PATH"] ?? "", "/usr/bin:/bin:/usr/sbin:/sbin"].filter { !$0.isEmpty }.joined(separator: ":")
        env["LOTC_OBSERVER"] = "1"
        env["CLAUDECODE"] = nil  // set when the app was started from inside a Claude Code session
        return env
    }
}

/// One line of `claude -p --output-format stream-json`.
enum StreamLine: Equatable {
    /// A piece of the reply's text (with --include-partial-messages).
    case textDelta(String)
    /// The text of a whole assistant message.
    case message(String)
    case result(text: String, isError: Bool, errors: [String])
    case other

    static func parse(_ line: String) -> StreamLine {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = json["type"] as? String
        else { return .other }
        switch type {
        case "stream_event":
            guard let event = json["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return .other }
            return .textDelta(text)
        case "assistant":
            let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            return texts.isEmpty ? .other : .message(texts.joined())
        case "result":
            return .result(text: json["result"] as? String ?? "", isError: json["is_error"] as? Bool ?? false,
                           errors: json["errors"] as? [String] ?? [])
        default:
            return .other
        }
    }
}

/// Lets a cancelled or timed-out turn stop its process from another thread.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var stopped = false
    private(set) var timedOut = false

    func start(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, (try? process.run()) != nil else { return false }
        self.process = process
        return true
    }

    func stop(timedOut: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        if let process, process.isRunning {
            stopped = true
            self.timedOut = timedOut
            process.terminate()
        } else if process == nil {
            stopped = true
        }
    }
}

/// Finds the `claude` command. An app opened from Finder gets a PATH without ~/.local/bin or Homebrew.
enum ClaudeBinary {
    /// Where its installers put it, after the PATH the app was given.
    static func usualPlaces(home: String) -> [String] {
        ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
         "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin"]
    }

    /// The setting's path, else the first `claude` on the PATH, in the usual places, then on the login shell's PATH.
    /// The login shell is asked only when nothing else has it, as it can take a second.
    static func find(override: String?, path: String?, home: String, loginPath: () -> String?,
                     isExecutable: (String) -> Bool) -> String? {
        if let override = override?.trimmedNonEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return isExecutable(expanded) ? expanded : nil
        }
        func first(in dirs: [String]) -> String? {
            dirs.lazy.filter { !$0.isEmpty }.map { $0 + "/claude" }.first(where: isExecutable)
        }
        let given = (path ?? "").split(separator: ":").map(String.init)
        return first(in: given + usualPlaces(home: home))
            ?? first(in: (loginPath() ?? "").split(separator: ":").map(String.init))
    }

    static func locate(override: String?) -> String? {
        find(override: override, path: ProcessInfo.processInfo.environment["PATH"],
             home: FileManager.default.homeDirectoryForCurrentUser.path,
             loginPath: { loginShellPath }, isExecutable: FileManager.default.isExecutableFile(atPath:))
    }

    /// The PATH an interactive login shell sets up, as a terminal would see it. Asked once.
    private static let loginShellPath: String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"]?.trimmedNonEmpty ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Markers, because an interactive shell's start-up files may print things of their own.
        process.arguments = ["-ilc", "printf '<lotc-path>%s</lotc-path>' \"$PATH\""]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return out.firstMatch(of: #/<lotc-path>(?<path>[^<]*)</lotc-path>/#).map { String($0.path) }
    }()
}
