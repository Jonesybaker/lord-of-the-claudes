import Foundation

/// Where a session's turn has got to, as Claude Code's registry says.
struct TurnStatus: Equatable, Sendable {
    /// "busy", "idle", or "waiting" when it needs the developer.
    let status: String
    let changedAt: Date
    /// What a waiting session needs, in Claude Code's words: "permission prompt", "input needed".
    var waitingFor: String?

    init(status: String, changedAt: Date, waitingFor: String? = nil) {
        self.status = status
        self.changedAt = changedAt
        self.waitingFor = waitingFor
    }

    init(_ session: LiveSession) {
        self.init(status: session.status, changedAt: session.statusUpdatedAt, waitingFor: session.waitingFor)
    }

    /// Stopped short of finishing: what it waits on, else nil.
    var stoppedFor: String? {
        switch status {
        case "busy", "idle": nil
        default: waitingFor?.trimmedNonEmpty ?? "a question or a permission prompt"
        }
    }
}

/// Whether a session has finished the work a prompt gave it.
enum TurnCheck {
    /// Not busy, and its status has changed since the prompt was typed.
    /// With nothing typed, finished as soon as it is not busy.
    static func hasFinished(status: String, statusChangedAt: Date, sentAt: Date?) -> Bool {
        guard status != "busy" else { return false }
        guard let sentAt else { return true }
        return statusChangedAt > sentAt
    }
}

/// Waits for a session to stop: `lotc wait`, and the app after it types a prompt.
enum TurnWatch {
    enum Outcome: Equatable {
        case finished(TurnStatus)
        /// Its process has gone.
        case closed
        /// Only with a deadline.
        case timedOut(TurnStatus)
        case cancelled
    }

    /// Finished twice running, as Claude Code can go idle for a moment between a turn and a prompt queued behind it.
    /// Once is enough at the deadline. No deadline waits for as long as it takes.
    static func wait(sentAt: Date?, deadline: Date? = nil, every interval: Duration = .seconds(1),
                     status: () async -> TurnStatus?) async -> Outcome {
        var finishedChecks = 0
        while true {
            if Task.isCancelled { return .cancelled }
            guard let now = await status() else { return .closed }
            let finished = TurnCheck.hasFinished(status: now.status, statusChangedAt: now.changedAt, sentAt: sentAt)
            finishedChecks = finished ? finishedChecks + 1 : 0
            let late = deadline.map { Date() >= $0 } ?? false
            if finishedChecks >= 2 || (finishedChecks == 1 && late) { return .finished(now) }
            if late { return .timedOut(now) }
            do { try await Task.sleep(for: interval) } catch { return .cancelled }
        }
    }
}

/// What the app reads to follow a session's turn: its status and its transcript. Tests fake it.
@MainActor
protocol SessionReading: AnyObject {
    /// Nil when it is not running.
    func status(of sessionId: String) async -> TurnStatus?
    /// Its last `count` exchanges, oldest first.
    func exchanges(of sessionId: String, cwd: String, last count: Int) async -> [Exchange]
    /// The session a new tab in `cwd` started since `date`, once Claude Code has registered it.
    func newSession(in cwd: String, since date: Date) async -> (id: String, startedAt: Date)?
}

/// Claude Code's own files, and the questions waiting in the app's permission window.
@MainActor
final class ClaudeSessionReader: SessionReading {
    func status(of sessionId: String) async -> TurnStatus? {
        guard let live = await Task.detached(operation: { ClaudeData.liveSessions().first { $0.sessionId == sessionId } }).value
        else { return nil }
        // A question held by the permission hook leaves Claude Code busy; the app knows better.
        if let asking = LotcServer.shared?.permissions.requests.first(where: { $0.input.sessionId == sessionId }) {
            return TurnStatus(status: "waiting", changedAt: asking.at,
                              waitingFor: "a permission prompt for \(asking.input.toolName), in the permission window")
        }
        return TurnStatus(live)
    }

    func exchanges(of sessionId: String, cwd: String, last count: Int) async -> [Exchange] {
        await Task.detached {
            guard let url = ClaudeData.transcriptURL(sessionId: sessionId, cwd: cwd) else { return [] }
            return SessionAnswers.exchanges(at: url, last: count)
        }.value
    }

    func newSession(in cwd: String, since date: Date) async -> (id: String, startedAt: Date)? {
        await Task.detached {
            ClaudeData.liveSessions()
                .compactMap { session in session.startedAt.map { (session, $0) } }
                .filter { TabMatch.samePath($0.0.cwd, cwd) && $0.1 >= date }
                .max { $0.1 < $1.1 }
                .map { (id: $0.0.sessionId, startedAt: $0.1) }
        }.value
    }
}
