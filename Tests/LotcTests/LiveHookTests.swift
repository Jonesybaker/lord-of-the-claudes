import Foundation
import Testing
@testable import LordOfTheClaudes
@testable import LotcKit

/// Runs real `claude -p` sessions with the permission hook pointed at this build's `lotc`, against a
/// server with made-up sessions on a private socket, so nothing reaches the installed app or Ghostty.
/// Costs a few Haiku calls, so it only runs when asked:
///   swift build && LOTC_LIVE_HOOK_TESTS=1 LOTC_SOCKET=/tmp/lotc-live/lotc.sock ./build.sh test --filter LiveHookTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOTC_LIVE_HOOK_TESTS"] == "1"), .serialized)
struct LiveHookTests {
    let dir = URL(fileURLWithPath: LotcSocket.path).deletingLastPathComponent()
    let lotc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/lotc").path

    private final class Watch {
        var mostQueued = 0
    }

    /// One `claude -p` with only the given tool, only this hook and no user settings. Returns its output.
    private func claude(_ prompt: String, tool: String) -> Process {
        let settings = #"{"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"\#(lotc) permission","timeout":600}]}]}}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "-p", prompt, "--model", "haiku", "--tools", tool, "--setting-sources", "project",
                             "--settings", settings, "--strict-mcp-config", "--permission-mode", "default"]
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func output(of program: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try await run(process)
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func run(_ process: Process) async throws {
        try process.run()
        await Task.detached { process.waitUntilExit() }.value
    }

    @Test func aRealSessionsSafeRequestsAreApprovedAndThePostQueues() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let approvals = AutoApprovals(files: .init(settings: dir.appendingPathComponent("auto-approve.json"),
                                                  log: dir.appendingPathComponent("auto-approve-log.json")))
        approvals.setOn(true)
        let store = Store(demoRows: [], approvals: approvals)
        LotcServer.start(store: store)
        let watch = Watch()
        let counting = store.$permissionRequestCount.sink { watch.mostQueued = max(watch.mostQueued, $0) }
        defer { counting.cancel() }

        try await run(claude("Use the WebFetch tool once on https://example.com and reply with the page's title only.", tool: "WebFetch"))
        try await run(claude("Use the WebSearch tool once to search for: Manchester United fixtures December. Reply with one line.",
                             tool: "WebSearch"))
        try await run(claude("Run exactly this Bash command and nothing else: curl -sS -o /dev/null -w '%{http_code}' https://example.com",
                             tool: "Bash"))
        print("Approved:\n" + approvals.log.map { "  \($0.tool) by \($0.rule): \($0.summary)" }.joined(separator: "\n"))
        #expect(approvals.log.contains { $0.tool == "WebFetch" && $0.summary.hasPrefix("https://example.com") })
        #expect(approvals.log.contains { $0.tool == "WebSearch" })
        #expect(approvals.log.contains { $0.tool == "Bash" && $0.rule == AutoApproveRule.shellGet.rawValue })
        #expect(watch.mostQueued == 0, "an approved request reached the window's queue")

        // `lotc approvals` from a terminal that is no Claude Code session.
        let log = try await output(of: lotc, ["approvals"])
        let status = try await output(of: lotc, ["approvals", "status"])
        print(log + "\n" + status)
        #expect(log.contains("Fetch a public page") && log.contains("https://example.com"))
        #expect(status.hasPrefix("Auto-approve: on"))

        let post = claude("Run exactly this Bash command and nothing else: curl -sS -X POST https://example.com", tool: "Bash")
        try post.run()
        for _ in 0..<600 where store.permissionRequestCount == 0 { try await Task.sleep(for: .milliseconds(100)) }
        let queued = LotcServer.shared?.permissions.front
        print("Queued: \(queued?.input.toolName ?? "nothing") \(queued?.input.toolInput["command"]?.string ?? "")\n  \(queued?.note ?? "no note")")
        #expect(store.permissionRequestCount == 1)
        #expect(queued?.note == "Not auto-approved: the method is POST, not GET")
        #expect(approvals.log.allSatisfy { !$0.summary.contains("POST") })
        // Hanging up the hook takes the question back, as answering in the terminal would.
        post.terminate()
        let hooks = Process()
        hooks.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        hooks.arguments = ["-f", lotc + " permission"]
        try await run(hooks)
        for _ in 0..<50 where post.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        if post.isRunning { kill(post.processIdentifier, SIGKILL) }
        for _ in 0..<50 where store.permissionRequestCount > 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(store.permissionRequestCount == 0)
    }
}
