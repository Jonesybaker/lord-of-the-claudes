import Foundation

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
