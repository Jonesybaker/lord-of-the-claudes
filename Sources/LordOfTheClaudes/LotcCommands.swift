import Foundation
import LotcKit

/// The `lotc` commands that act on the caller's group: the sessions in its Ghostty window.
extension LotcServer {
    static let notTracked = """
        Lord of the Claudes cannot see this session in a Ghostty tab. It matches tabs by title, \
        so a new or renamed session takes up to 5 seconds to appear. Two new sessions in one \
        directory appear once Claude has titled them.
        """

    func run(_ command: LotcCommand, caller: String?) async -> LotcResponse {
        guard let caller,
              let group = store.groups.first(where: { $0.rows.contains { $0.id == caller } })
        else { return .failure(Self.notTracked) }
        let summary = { (row: Row) in Self.summary(of: row, caller: caller) }

        switch command {
        case .list:
            return .window(WindowListing(group: group.name, sessions: group.rows.map(summary)))

        case .send(let tab, let prompt):
            let row: Row
            switch SessionTarget.find(tab, in: group.rows) {
            case .failure(let problem): return .failure(problem.message)
            case .success(let found): row = found
            }
            guard row.id != caller else { return .failure("Tab \(row.tab ?? 0) is you. Send to one of the other tabs.") }
            guard await type(prompt, into: row) else { return .failure(Self.cannotType(row)) }
            return .sent(to: [summary(row)], missed: [])

        case .broadcast(let prompt):
            let siblings = group.rows.filter { $0.id != caller }
            guard !siblings.isEmpty else { return .failure("There are no other sessions in \(group.name).") }
            var reached: [SessionSummary] = []
            var missed: [SessionSummary] = []
            for row in siblings {
                if await type(prompt, into: row) { reached.append(summary(row)) } else { missed.append(summary(row)) }
            }
            return .sent(to: reached, missed: missed)

        case .wait(let tab, let timeout):
            switch SessionTarget.find(tab, in: group.rows) {
            case .failure(let problem): return .failure(problem.message)
            case .success(let row): return await waitForTurn(of: row, timeout: timeout, caller: caller)
            }

        case .last(let tab):
            switch SessionTarget.find(tab, in: group.rows) {
            case .failure(let problem): return .failure(problem.message)
            case .success(let row): return .message(LastMessage(session: summary(row), text: await lastText(of: row)))
            }

        case .lord:
            store.makeLord(caller)
            return .lord(group: group.name)

        case .permission:
            return .failure("Permission requests are answered elsewhere.")
        }
    }

    /// Types the prompt and notes when, so `lotc wait` can tell the turn it started from earlier ones.
    private func type(_ prompt: String, into row: Row) async -> Bool {
        let startedAt = Date()
        guard await store.send(prompt, toSession: row.id) else { return false }
        lastSentAt[row.id] = startedAt
        return true
    }

    private func waitForTurn(of row: Row, timeout: TimeInterval, caller: String) async -> LotcResponse {
        let tab = row.tab ?? 0
        let sentAt = lastSentAt[row.id]
        let deadline = Date().addingTimeInterval(timeout)
        var finishedChecks = 0
        var status = row.status ?? "closed"
        while true {
            let id = row.id
            guard let session = await Task.detached(operation: { ClaudeData.liveSessions().first { $0.sessionId == id } }).value
            else { return .failure("Tab \(tab) (\(row.title)) is no longer running.") }
            status = session.status
            let finished = TurnCheck.hasFinished(status: session.status, statusChangedAt: session.statusUpdatedAt, sentAt: sentAt)
            finishedChecks = finished ? finishedChecks + 1 : 0
            // Twice running: Claude Code can go idle for a moment between a turn and a prompt queued behind it.
            if finishedChecks >= 2 || (finishedChecks == 1 && Date() >= deadline) { break }
            if Date() >= deadline {
                return .failure("""
                    Tab \(tab) (\(row.title)) has not finished after \(Int(timeout)) seconds (status: \(status)). \
                    Run lotc wait \(tab) again to keep waiting.
                    """)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        var session = Self.summary(of: row, caller: caller)
        session.status = status
        return .message(LastMessage(session: session, text: await lastText(of: row)))
    }

    private func lastText(of row: Row) async -> String {
        let (id, cwd) = (row.id, row.cwd)
        return await Task.detached {
            guard let url = ClaudeData.transcriptURL(sessionId: id, cwd: cwd) else { return "" }
            return Transcript.lastAssistantText(at: url)
        }.value
    }

    static func summary(of row: Row, caller: String) -> SessionSummary {
        SessionSummary(
            tab: row.tab ?? 0, title: row.title, sessionId: row.id, cwd: row.cwd,
            status: row.status ?? "closed", waitingForYou: row.needsYou, isLord: row.isLord,
            isCaller: row.id == caller)
    }

    private static func cannotType(_ row: Row) -> String {
        "Could not type into tab \(row.tab ?? 0) (\(row.title)). Its Ghostty tab may have been renamed or closed."
    }
}

/// Whether a session has finished the work `lotc send` gave it.
enum TurnCheck {
    /// Not busy, and its status has changed since the prompt was typed.
    /// With nothing typed, finished as soon as it is not busy.
    static func hasFinished(status: String, statusChangedAt: Date, sentAt: Date?) -> Bool {
        guard status != "busy" else { return false }
        guard let sentAt else { return true }
        return statusChangedAt > sentAt
    }
}

/// Finds the session a `lotc` command means: a tab number, or a piece of one title no other title has.
enum SessionTarget {
    struct Problem: Error {
        let message: String
    }

    static func find(_ target: String, in rows: [Row]) -> Result<Row, Problem> {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return .failure(Problem(message: "Name a tab: its number or part of its title.")) }
        if let number = Int(target) {
            guard let row = rows.first(where: { $0.tab == number }) else {
                return .failure(Problem(message: "There is no tab \(number) in this window. lotc list shows them."))
            }
            return .success(row)
        }
        let matches = rows.filter { $0.title.localizedCaseInsensitiveContains(target) }
        switch matches.count {
        case 1:
            return .success(matches[0])
        case 0:
            return .failure(Problem(message: "No session in this window has \"\(target)\" in its title. lotc list shows them."))
        default:
            let names = matches.map { "tab \($0.tab ?? 0) (\($0.title))" }.joined(separator: ", ")
            return .failure(Problem(message: "\"\(target)\" matches \(names). Use the tab number."))
        }
    }
}
