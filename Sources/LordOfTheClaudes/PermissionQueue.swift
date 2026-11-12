import Foundation
import LotcKit

/// Permission questions from `lotc permission`, oldest first. The window asks the first one.
@MainActor
final class PermissionQueue: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let input: PermissionHookInput
        let origin: Origin
    }

    /// Where a request came from, worked out when it arrived.
    struct Origin {
        /// The tracked session to focus for "Answer in the terminal"; nil when the app does not track it.
        let sessionId: String?
        /// Its title and tab, or its directory when it is not tracked.
        let label: String
        /// Its directory, or why it has no tab.
        let detail: String
    }

    /// A question's buttons only work once it has been on screen this long, so a key already on
    /// its way, or held down, cannot answer a question nobody has read.
    static let armingDelay: TimeInterval = 0.6

    @Published private(set) var requests: [Request] = [] {
        didSet { if requests.first?.id != oldValue.first?.id { frontSince = Date() } }
    }
    private(set) var frontSince = Date.distantPast
    private var waiting: [UUID: CheckedContinuation<PermissionAnswer, Never>] = [:]

    var front: Request? { requests.first }
    var isFrontArmed: Bool { Date().timeIntervalSince(frontSince) >= Self.armingDelay }

    func ask(_ request: Request) async -> PermissionAnswer {
        await withCheckedContinuation { continuation in
            waiting[request.id] = continuation
            requests.append(request)
        }
    }

    func answer(_ id: UUID, with answer: PermissionAnswer) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        requests.removeAll { $0.id == id }
        continuation.resume(returning: answer)
    }

    /// Its hook has gone: answered in the terminal, or timed out.
    func withdraw(_ id: UUID) {
        answer(id, with: .askInTerminal)
    }
}

/// What Claude Code passes a PermissionRequest hook on stdin.
struct PermissionHookInput {
    let sessionId: String
    let cwd: String
    let toolName: String
    let toolInput: JSONValue
    /// Set when a subagent is asking, e.g. "Explore".
    let agentType: String?

    init?(json: String) {
        guard let value = try? JSONValue(parsing: json),
              let toolName = value["tool_name"]?.string
        else { return nil }
        sessionId = value["session_id"]?.string ?? ""
        cwd = value["cwd"]?.string ?? ""
        self.toolName = toolName
        toolInput = value["tool_input"] ?? .null
        agentType = value["agent_type"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A tool's input in the shape a person reads it best.
enum ToolPreview: Equatable {
    case command(String, description: String?)
    case edit(file: String, old: String, new: String, everyOccurrence: Bool)
    case write(file: String, content: String)
    case json(String)

    init(toolName: String, input: JSONValue) {
        switch toolName {
        case "Bash":
            if let command = input["command"]?.string {
                self = .command(command, description: input["description"]?.string)
                return
            }
        case "Edit":
            if let file = input["file_path"]?.string, let old = input["old_string"]?.string,
               let new = input["new_string"]?.string {
                self = .edit(file: file, old: old, new: new, everyOccurrence: input["replace_all"] == .bool(true))
                return
            }
        case "Write":
            if let file = input["file_path"]?.string, let content = input["content"]?.string {
                self = .write(file: file, content: content)
                return
            }
        default:
            break
        }
        self = .json(input.formatted())
    }

    static func headline(toolName: String) -> String {
        switch toolName {
        case "Bash": return "Claude wants to run a command"
        case "Edit": return "Claude wants to edit a file"
        case "Write": return "Claude wants to write a file"
        default: return "Claude wants to use \(toolName)"
        }
    }
}
