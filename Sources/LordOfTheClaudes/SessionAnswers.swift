import Foundation

/// One prompt typed into a session and the answer that ended that turn.
struct Exchange: Equatable, Sendable {
    /// Nil when the transcript read starts partway through a turn.
    var prompt: String?
    /// The turn's final assistant message, with any question or plan it put to the developer. Empty until written.
    var answer: String
}

/// What a session said, from its transcript: the developer's prompts and Claude's final words. Never tool
/// calls, tool results or images.
enum SessionAnswers {
    /// What one answer may take of what the overseer is sent, and of a session's page.
    static let answerCharacters = 6_000
    /// Earlier answers in a read of several exchanges, and every prompt.
    static let earlierAnswerCharacters = 1_500
    static let promptCharacters = 1_000
    static let tailBytes: UInt64 = 4 * 1024 * 1024

    /// The last `count` exchanges of a transcript, oldest first.
    static func exchanges(at url: URL, last count: Int) -> [Exchange] {
        let tail = exchanges(in: ClaudeData.readTail(url, bytes: tailBytes))
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard !tail.contains(where: { !$0.answer.isEmpty }), size > Int(tailBytes), let whole = try? Data(contentsOf: url)
        else { return Array(tail.suffix(count)) }
        return Array(exchanges(in: whole).suffix(count))
    }

    /// Claude Code writes each block of a message as its own line under the message's id, so a turn's final
    /// answer is every block with words carrying the last id that has any. Subagents and injected lines are skipped.
    static func exchanges(in data: Data) -> [Exchange] {
        var exchanges: [Exchange] = []
        var answerId: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  json["isSidechain"] as? Bool != true, json["isMeta"] as? Bool != true,
                  json["isCompactSummary"] as? Bool != true,
                  let message = json["message"] as? [String: Any]
            else { continue }
            switch json["type"] as? String {
            case "user":
                let human = ((json["origin"] as? [String: Any])?["kind"] as? String ?? "human") == "human"
                guard human, let prompt = prompt(in: message["content"]) else { continue }
                exchanges.append(Exchange(prompt: prompt, answer: ""))
                answerId = nil
            case "assistant":
                let said = words(in: message["content"])
                if exchanges.isEmpty { exchanges.append(Exchange(prompt: nil, answer: "")) }
                let id = message["id"] as? String
                if let id, id == answerId {
                    exchanges[exchanges.count - 1].answer = ([exchanges[exchanges.count - 1].answer] + said)
                        .filter { !$0.isEmpty }.joined(separator: "\n\n")
                } else if !said.isEmpty {
                    answerId = id  // without ids the lines of one message cannot be told apart: each stands alone
                    exchanges[exchanges.count - 1].answer = said.joined(separator: "\n\n")
                }
            default:
                continue
            }
        }
        return exchanges
    }

    /// The developer's words in a user line. Tool results, images, interruptions and command output are not.
    private static func prompt(in content: Any?) -> String? {
        let texts: [String]
        if let text = content as? String {
            texts = [text]
        } else {
            texts = (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        guard let text = texts.joined(separator: "\n\n").trimmedNonEmpty,
              !text.hasPrefix("[Request interrupted by user"),
              !text.hasPrefix("<local-command-"), !text.hasPrefix("<bash-stdout>"), !text.hasPrefix("<bash-stderr>")
        else { return nil }
        if let command = text.firstMatch(of: #/<command-name>(?<name>[^<]*)</command-name>/#) {
            let args = text.firstMatch(of: #/<command-args>(?<args>[^<]*)</command-args>/#).map { String($0.args) } ?? ""
            return [String(command.name), args].compactMap(\.trimmedNonEmpty).joined(separator: " ")
        }
        if let bash = text.firstMatch(of: #/<bash-input>(?<input>[\s\S]*?)</bash-input>/#) { return "!" + bash.input }
        return text
    }

    /// Claude's words in an assistant line: its text, and the questions or plan it put to the developer.
    private static func words(in content: Any?) -> [String] {
        if let text = content as? String { return text.trimmedNonEmpty.map { [$0] } ?? [] }
        return (content as? [[String: Any]] ?? []).compactMap { block -> String? in
            switch block["type"] as? String {
            case "text":
                return (block["text"] as? String)?.trimmedNonEmpty
            case "tool_use":
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "AskUserQuestion": return questions(input["questions"])
                case "ExitPlanMode": return (input["plan"] as? String)?.trimmedNonEmpty.map { "Its plan, waiting for approval:\n\n" + $0 }
                default: return nil
                }
            default:
                return nil
            }
        }
    }

    private static func questions(_ value: Any?) -> String? {
        let asked = (value as? [[String: Any]] ?? []).compactMap { question -> String? in
            guard let text = (question["question"] as? String)?.trimmedNonEmpty else { return nil }
            let several = question["multiSelect"] as? Bool == true ? " (any number)" : ""
            let options = (question["options"] as? [[String: Any]] ?? []).enumerated().compactMap { index, option -> String? in
                guard let label = (option["label"] as? String)?.trimmedNonEmpty else { return nil }
                let detail = (option["description"] as? String)?.trimmedNonEmpty.map { ": " + $0 } ?? ""
                return "\(index + 1). \(label)\(detail)"
            }
            return (["It asks: \(text)\(several)"] + options).joined(separator: "\n")
        }
        return asked.isEmpty ? nil : asked.joined(separator: "\n\n")
    }

    /// Longer than `limit`, it keeps its start and its end, where the summary and the question usually are,
    /// with a marked gap between.
    static func capped(_ text: String, to limit: Int = answerCharacters) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let half = max((limit - 48) / 2, 1)
        let marker = "[... \((text.count - 2 * half).formatted()) characters left out ...]"
        return text.prefix(half).trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + marker + "\n\n"
            + text.suffix(half).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
