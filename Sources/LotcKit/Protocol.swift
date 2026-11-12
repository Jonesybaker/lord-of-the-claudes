import Foundation

/// One request from `lotc` to the app, sent as a single JSON line.
public struct LotcRequest: Codable, Sendable {
    /// The Claude Code session that ran `lotc`. Nil for the permission hook, whose input names its session.
    public var caller: String?
    public var command: LotcCommand

    public init(caller: String?, command: LotcCommand) {
        self.caller = caller
        self.command = command
    }
}

/// `tab` is a tab number in the caller's window, or a piece of one session's title.
public enum LotcCommand: Codable, Sendable, Equatable {
    case list
    case send(tab: String, prompt: String)
    case broadcast(prompt: String)
    case wait(tab: String, timeout: Double)
    case last(tab: String)
    case lord
    /// The PermissionRequest hook's stdin, passed through untouched for the app to read.
    case permission(hookInput: String)
}

/// The app's one-line answer to a request.
public enum LotcResponse: Codable, Sendable, Equatable {
    case window(WindowListing)
    /// `missed`: sessions whose tab the prompt could not be typed into.
    case sent(to: [SessionSummary], missed: [SessionSummary])
    case message(LastMessage)
    case lord(group: String)
    case permission(PermissionAnswer)
    case failure(String)
}

public struct WindowListing: Codable, Sendable, Equatable {
    public var group: String
    public var sessions: [SessionSummary]

    public init(group: String, sessions: [SessionSummary]) {
        self.group = group
        self.sessions = sessions
    }
}

public struct SessionSummary: Codable, Sendable, Equatable {
    public var tab: Int
    public var title: String
    public var sessionId: String
    public var cwd: String
    /// Claude Code's own word for it: "busy" while it works, otherwise usually "idle".
    public var status: String
    /// It has finished and nobody has looked at its tab since.
    public var waitingForYou: Bool
    public var isLord: Bool
    /// This is the session that ran `lotc`.
    public var isCaller: Bool

    public var isWorking: Bool { status == "busy" }

    public init(tab: Int, title: String, sessionId: String, cwd: String, status: String,
                waitingForYou: Bool, isLord: Bool, isCaller: Bool) {
        self.tab = tab
        self.title = title
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.waitingForYou = waitingForYou
        self.isLord = isLord
        self.isCaller = isCaller
    }
}

public struct LastMessage: Codable, Sendable, Equatable {
    public var session: SessionSummary
    /// Empty when the session has not said anything yet.
    public var text: String

    public init(session: SessionSummary, text: String) {
        self.session = session
        self.text = text
    }
}

public enum PermissionAnswer: Codable, Sendable, Equatable {
    case allow
    /// `interrupt` stops Claude's turn; without it Claude reads `message` and carries on.
    case deny(message: String, interrupt: Bool)
    /// No decision: Claude Code asks in the terminal as it would without the hook.
    case askInTerminal
}

/// The PermissionRequest hook as `lotc hooks install` writes it.
public enum PermissionHook {
    /// Claude Code kills the hook after this long.
    public static let timeout = 600
    /// `lotc permission` gives up a little sooner, so it can exit cleanly and leave the question to the terminal.
    public static let deadline = TimeInterval(timeout - 10)
}
