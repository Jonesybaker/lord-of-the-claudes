import Foundation
import LotcKit

/// `lotc observe`: Claude Code runs it as a Stop hook. It hands the stop to the app and is gone.
/// It fails open and says nothing: no output, no answer awaited, exit 0 whatever happens,
/// so it can never hold Claude up or read to Claude Code as a decision to block.
enum ObserveCommand {
    /// Main's watchdog: Claude Code writes stdin and closes it at once, so anything longer is something stuck.
    static let deadline: TimeInterval = 2

    static func run(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readInput: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
        send: (LotcRequest) -> Void = deliver
    ) -> Int32 {
        guard !ObserverRun.isActive(environment) else { return 0 }
        guard let text = String(data: readInput(), encoding: .utf8),
              let input = try? JSONValue(parsing: text),
              let event = StopEvent(hookInput: input)
        else { return 0 }
        send(LotcRequest(caller: nil, command: .observe(event)))
        return 0
    }

    /// One line to the app, not waiting for its answer. Nothing listening is fine: the app is not running.
    static func deliver(_ request: LotcRequest) {
        guard let connection = try? LineConnection.connect(to: LotcSocket.path) else { return }
        defer { connection.close() }
        try? connection.send(request)
    }
}
