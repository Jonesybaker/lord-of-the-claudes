import Foundation
import LotcKit

/// What a session last said, from its transcript (~/.claude/projects/<dir>/<session>.jsonl).
enum Transcript {
    /// The text of the last assistant message, or "" when there is none.
    static func lastAssistantText(at url: URL) -> String {
        // The answer is near the end, and a long transcript takes seconds to read in full.
        if let text = lastAssistantText(in: ClaudeData.readTail(url, bytes: 4 * 1024 * 1024)) { return text }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 4 * 1024 * 1024, let whole = try? Data(contentsOf: url) else { return "" }
        return lastAssistantText(in: whole) ?? ""
    }

    /// Claude Code writes each block of a message (thinking, text, tool use) as its own line under the
    /// same message id, so the last message's text is every text block carrying the last id that has any.
    static func lastAssistantText(in data: Data) -> String? {
        let marker = Data(#""type":"assistant""#.utf8)
        let decoder = JSONDecoder()
        var messageId: String?
        var texts: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.range(of: marker) != nil,
                  let entry = try? decoder.decode(Entry.self, from: line),
                  entry.type == "assistant", entry.isSidechain != true,
                  let message = entry.message
            else { continue }
            let lineTexts = message.content?.texts ?? []
            if let messageId {
                guard message.id == messageId else { break }
                texts = lineTexts + texts
            } else if !lineTexts.isEmpty {
                messageId = message.id ?? ""
                texts = lineTexts
                if message.id == nil { break }  // without ids the lines of one message cannot be told apart
            }
        }
        return messageId == nil ? nil : texts.joined(separator: "\n\n")
    }

    // MARK: Excerpts for the observer

    /// Bounds on what is read and sent: only the end of a transcript matters, and its first prompt.
    static let excerptTailBytes: UInt64 = 1024 * 1024
    static let excerptHeadBytes = 256 * 1024
    static let excerptTurns = 40
    static let excerptCharacters = 16_000
    static let turnCharacters = 1_200

    /// One step of a session, as the summariser reads it.
    enum Turn: Equatable {
        case user(String)
        /// A message to Claude from elsewhere: a background task finishing, another session.
        case note(String)
        case claude(String)
        /// "Bash: git status".
        case tool(String)
    }

    /// The end of the session's transcript, with its title and first prompt. Nil when there is nothing to read.
    static func excerpt(of event: StopEvent) -> Excerpt? {
        guard let url = transcriptURL(of: event) else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let tail = ClaudeData.readTail(url, bytes: excerptTailBytes)
        let head = size > Int(excerptTailBytes) ? readHead(url, bytes: excerptHeadBytes) : nil
        guard let text = excerpt(tail: tail, head: head, cwd: event.cwd, lastMessage: event.lastAssistantMessage)
        else { return nil }
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return Excerpt(text: text, fingerprint: "\(size) \(modified) \(event.lastAssistantMessage?.hashValue ?? 0)")
    }

    /// Claude's own registry first. The hook's path is taken only when it names this session's transcript.
    private static func transcriptURL(of event: StopEvent) -> URL? {
        if let cwd = event.cwd, let url = ClaudeData.transcriptURL(sessionId: event.sessionId, cwd: cwd) { return url }
        guard let path = event.transcriptPath.map({ ($0 as NSString).expandingTildeInPath }),
              (path as NSString).lastPathComponent == event.sessionId + ".jsonl",
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func readHead(_ url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: bytes)
    }

    /// The text the summariser reads. `head` is the start of a transcript too long for `tail` to hold it all.
    static func excerpt(tail: Data, head: Data?, cwd: String?, lastMessage: String?) -> String? {
        var turns = Array(self.turns(in: tail).suffix(excerptTurns))
        if let lastMessage, !lastMessage.isEmpty {
            // At Stop time the transcript can lack the reply that ended the turn.
            let ending = String(lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))
            let written = turns.contains { if case .claude(let text) = $0 { return text.contains(ending) }; return false }
            if !written { turns.append(.claude(lastMessage)) }
        }
        guard !turns.isEmpty else { return nil }

        var context: [String] = []
        if let title = ClaudeData.findTitle(in: tail) { context.append("Title: " + title) }
        if let cwd { context.append("Working directory: " + cwd) }
        if let head, let first = self.turns(in: head).first(where: { if case .user = $0 { return true }; return false }),
           case .user(let text) = first {
            context.append("First prompt: " + shortened(text))
        }

        var lines: [String] = []
        var budget = excerptCharacters
        for turn in turns.reversed() {
            let line = render(turn)
            guard budget - line.count > 0 || lines.isEmpty else { break }
            budget -= line.count
            lines.insert(line, at: 0)
        }
        return (context + ["", "The latest part of the transcript, oldest first:"] + lines).joined(separator: "\n")
    }

    private static func render(_ turn: Turn) -> String {
        switch turn {
        case .user(let text): return "User: " + shortened(text)
        case .note(let text): return "Message to Claude: " + shortened(text)
        case .claude(let text): return "Claude: " + shortened(text)
        case .tool(let call): return "Claude ran " + call
        }
    }

    /// Long texts keep their start and their end, where the ask and the question usually are.
    private static func shortened(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > turnCharacters else { return text }
        let half = turnCharacters / 2
        return String(text.prefix(half)) + " [...] " + String(text.suffix(half))
    }

    /// The user's prompts, Claude's replies and the tools it ran, in order. Subagents and Claude Code's own
    /// injected messages are left out, as are lines cut in half by reading from the middle of the file.
    static func turns(in data: Data) -> [Turn] {
        var turns: [Turn] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  json["isSidechain"] as? Bool != true, json["isMeta"] as? Bool != true,
                  let message = json["message"] as? [String: Any]
            else { continue }
            switch json["type"] as? String {
            case "user":
                let human = ((json["origin"] as? [String: Any])?["kind"] as? String ?? "human") == "human"
                for text in texts(message["content"]) { turns.append(human ? .user(text) : .note(text)) }
            case "assistant":
                guard let blocks = message["content"] as? [[String: Any]] else {
                    if let text = message["content"] as? String, !text.isEmpty { turns.append(.claude(text)) }
                    continue
                }
                for block in blocks {
                    switch block["type"] as? String {
                    case "text": if let text = block["text"] as? String, !text.isEmpty { turns.append(.claude(text)) }
                    case "tool_use": turns.append(.tool(toolCall(block)))
                    default: break
                    }
                }
            default:
                continue
            }
        }
        return turns
    }

    /// A user message's own words: tool results and images are not the user speaking.
    private static func texts(_ content: Any?) -> [String] {
        if let text = content as? String { return text.isEmpty ? [] : [text] }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.filter { !$0.isEmpty }
    }

    /// The tool and the one input that says what it did.
    private static func toolCall(_ block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "a tool"
        let input = block["input"] as? [String: Any] ?? [:]
        let detail = ["command", "file_path", "pattern", "url", "description", "prompt"].lazy
            .compactMap { input[$0] as? String }.first
        guard let detail else { return name }
        let line = detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return name + ": " + (line.count > 150 ? String(line.prefix(149)) + "…" : line)
    }

    private struct Entry: Decodable {
        let type: String?
        let isSidechain: Bool?
        let message: Message?
    }

    private struct Message: Decodable {
        let id: String?
        let content: Content?
    }

    /// Usually a list of blocks; older transcripts have a plain string.
    private enum Content: Decodable {
        case plain(String)
        case blocks([Block])

        var texts: [String] {
            switch self {
            case .plain(let text): return text.isEmpty ? [] : [text]
            case .blocks(let blocks): return blocks.compactMap { $0.type == "text" ? $0.text : nil }.filter { !$0.isEmpty }
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .plain(text)
            } else {
                self = .blocks(try container.decode([Block].self))
            }
        }
    }

    private struct Block: Decodable {
        let type: String
        let text: String?
    }
}
