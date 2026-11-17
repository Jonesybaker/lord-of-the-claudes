import Foundation

/// What Claude Code's Stop hook tells `lotc observe`, passed on to the app to summarise.
public struct StopEvent: Codable, Sendable, Equatable {
    /// Longer replies are cut to their end, where a question to the user usually is.
    public static let messageCap = 4000

    public var sessionId: String
    public var transcriptPath: String?
    public var cwd: String?
    /// Claude's reply that ended the turn. At Stop time the transcript may not hold it yet (hooks reference, "Stop input").
    public var lastAssistantMessage: String?

    public init(sessionId: String, transcriptPath: String? = nil, cwd: String? = nil, lastAssistantMessage: String? = nil) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.lastAssistantMessage = lastAssistantMessage
    }

    /// Nil unless the input names its session.
    public init?(hookInput: JSONValue) {
        guard let sessionId = hookInput["session_id"]?.string, !sessionId.isEmpty else { return nil }
        let message = hookInput["last_assistant_message"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        self.init(sessionId: sessionId, transcriptPath: hookInput["transcript_path"]?.string,
                  cwd: hookInput["cwd"]?.string, lastAssistantMessage: message.map { String($0.suffix(Self.messageCap)) })
    }
}

/// The app's summariser runs are Claude Code sessions too, and fire the same hooks. It marks them with this
/// variable so `lotc observe` and `lotc permission` stand aside instead of starting a loop.
public enum ObserverRun {
    public static let variable = "LOTC_OBSERVER"

    public static func isActive(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[variable] == "1"
    }
}
