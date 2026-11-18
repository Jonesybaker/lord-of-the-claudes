import Foundation

/// The turns the app gives the overseer itself: what sessions said after a prompt, and what a read found.
/// A session's words are untrusted, so they go inside <session-answer> tags they cannot close.
extension OverseerPrompt {
    static let appTag = "<from-the-app>"

    /// What the sessions said after the developer's prompt: one turn for the lot.
    static func report(_ replies: [SessionReply], broadcast: String?) -> String {
        let several = replies.count > 1
        var lead = "Not typed by the developer: the app waited for "
            + (several ? "these sessions" : "this session") + " to stop after the developer's prompt and read what "
            + (several ? "each" : "it") + " said."
        if let broadcast { lead += " The developer sent one prompt to every session in \(broadcast)." }
        lead += " Report back to the developer."
        if several { lead += " A short line for each session, what differs between them, and which ask the developer something." }
        let blocks = replies.map { reply in
            var lines = ["<session-answer>", "Session: \(link(reply.place))",
                         "Prompt sent: " + neutralised(SessionAnswers.capped(reply.prompt, to: SessionAnswers.promptCharacters)),
                         "Outcome: " + outcome(reply.outcome)]
            if let answer = reply.answer.trimmedNonEmpty {
                lines += ["Its answer:", neutralised(SessionAnswers.capped(answer))]
            } else if reply.outcome == .finished || isWaiting(reply.outcome) {
                lines.append("Its transcript has no answer to read.")
            }
            return (lines + ["</session-answer>"]).joined(separator: "\n")
        }
        return ([appTag + "\n" + lead + "\n</from-the-app>"] + blocks).joined(separator: "\n\n")
    }

    /// A read's result: the session's latest exchanges, oldest first, the last answer given the most room.
    static func read(_ place: SessionPlace, _ exchanges: [Exchange]) -> String {
        let lead = "Not typed by the developer: you asked to read \(link(place)). Its latest exchanges are below, "
            + "oldest first. Answer the developer's last message from them."
        var lines = ["<session-answer>", "Session: \(link(place))"]
        if exchanges.isEmpty { lines.append("Its transcript has nothing to read yet.") }
        for (index, exchange) in exchanges.enumerated() {
            let room = index == exchanges.count - 1 ? SessionAnswers.answerCharacters : SessionAnswers.earlierAnswerCharacters
            lines.append("Prompt: " + (exchange.prompt.map { neutralised(SessionAnswers.capped($0, to: SessionAnswers.promptCharacters)) }
                                        ?? "(from before what was read)"))
            lines.append(exchange.answer.isEmpty ? "Answer: none yet; it may still be working."
                                                 : "Answer:\n" + neutralised(SessionAnswers.capped(exchange.answer, to: room)))
        }
        return [appTag + "\n" + lead + "\n</from-the-app>", (lines + ["</session-answer>"]).joined(separator: "\n")]
            .joined(separator: "\n\n")
    }

    static func unread(_ why: String) -> String {
        appTag + "\nNot typed by the developer: the app could not read that session. " + why
            + " Answer the developer's last message from what you have, or ask which session they mean.\n</from-the-app>"
    }

    /// [Its title](session:Shop/2), as the overseer names sessions.
    static func link(_ place: SessionPlace) -> String {
        let title = place.title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[\(title)](session:\(place.tab.map { "\(place.group)/\($0)" } ?? place.group))"
    }

    /// A session's text cannot open or close the tags that frame it.
    static func neutralised(_ text: String) -> String {
        text.replacing(#/<(?=\s*/?\s*(?:session-answer|from-the-app|briefing|since-your-last-answer|earlier-conversation)\b)/#
            .ignoresCase(), with: "‹")
    }

    private static func outcome(_ outcome: SessionReply.Outcome) -> String {
        switch outcome {
        case .finished: "it finished its turn."
        case .waiting(let reason): "it stopped short of finishing and is waiting for the developer: \(reason)."
        case .closed: "it closed before it answered."
        case .lost: "the new session could not be found, so nothing was read."
        }
    }

    private static func isWaiting(_ outcome: SessionReply.Outcome) -> Bool {
        if case .waiting = outcome { true } else { false }
    }
}

/// Reads one message may lead to, so a read cannot set off reads without end.
struct ReadBudget: Equatable {
    static let reads = 3

    private(set) var used = 0
    /// Reads of each session that a read's own follow-up asked for.
    private(set) var rereads: [String: Int] = [:]
    /// The turn being answered is a read's follow-up.
    private(set) var afterRead = false

    var exhausted: Bool { used >= Self.reads }

    /// Three in all; a read's follow-up may read the same session once more, no further.
    func allows(_ rowId: String) -> Bool {
        !exhausted && !(afterRead && rereads[rowId, default: 0] >= 1)
    }

    mutating func spend(on rowId: String) {
        used += 1
        if afterRead { rereads[rowId, default: 0] += 1 }
        afterRead = true
    }
}
