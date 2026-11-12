import Foundation
import LotcKit

/// `lotc permission`: Claude Code runs it as a PermissionRequest hook, and it waits for the answer
/// given in Lord of the Claudes. It fails open: whatever goes wrong, it exits 0 with no output,
/// and Claude Code asks in the terminal as it would without the hook.
enum PermissionHookCommand {
    static func run() -> Int32 {
        let deadline = Date().addingTimeInterval(PermissionHook.deadline)
        // Whatever blocks, never be the hook Claude Code has to kill.
        DispatchQueue.global().asyncAfter(deadline: .now() + PermissionHook.deadline) { exit(0) }

        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let hookInput = String(data: input, encoding: .utf8), !hookInput.isEmpty,
              let connection = try? LineConnection.connect(to: LotcSocket.path)
        else { return 0 }
        defer { connection.close() }

        if let watch = (try? JSONValue(parsing: hookInput)).flatMap(AnsweredElsewhere.init) {
            Thread.detachNewThread {
                while true {
                    Thread.sleep(forTimeInterval: 1)
                    // Answered in the terminal: going away is what takes the question off the screen.
                    if watch.hasHappened() { exit(0) }
                }
            }
        }
        guard (try? connection.send(LotcRequest(caller: nil, command: .permission(hookInput: hookInput)))) != nil,
              let response = try? connection.receive(LotcResponse.self, timeout: deadline.timeIntervalSinceNow),
              case .permission(let answer) = response,
              let reply = HookReply(answer)
        else { return 0 }
        print(reply.json)
        return 0
    }
}

/// What a PermissionRequest hook prints for Claude Code to act on.
struct HookReply: Encodable {
    struct Specific: Encodable {
        var hookEventName = "PermissionRequest"
        let decision: Decision
    }

    struct Decision: Encodable {
        let behavior: String
        var message: String?
        var interrupt: Bool?
    }

    let hookSpecificOutput: Specific

    /// Nil for "ask in the terminal": the hook then prints nothing at all.
    init?(_ answer: PermissionAnswer) {
        switch answer {
        case .allow:
            hookSpecificOutput = Specific(decision: Decision(behavior: "allow"))
        case .deny(let message, let interrupt):
            hookSpecificOutput = Specific(decision: Decision(behavior: "deny", message: message, interrupt: interrupt))
        case .askInTerminal:
            return nil
        }
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
