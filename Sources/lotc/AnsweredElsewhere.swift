import Foundation
import LotcKit

/// Notices when the question a `lotc permission` hook is asking has been answered without it.
/// Claude Code shows its own prompt in the terminal while the hook runs; answered there, it writes
/// the tool's result to the transcript but leaves the hook running until its timeout.
/// Used by one thread at a time, hence `@unchecked`.
final class AnsweredElsewhere: @unchecked Sendable {
    private static let lookBack: UInt64 = 2 * 1024 * 1024

    private let transcript: URL
    private let toolName: String
    private let toolInput: JSONValue
    /// Ids of the calls in the transcript that match the one being asked about.
    private var callIds: Set<String> = []
    /// How far the transcript has been read. Only results written after the hook started count.
    private var offset: UInt64

    init?(hookInput: JSONValue) {
        guard let path = hookInput["transcript_path"]?.string,
              let toolName = hookInput["tool_name"]?.string,
              let toolInput = hookInput["tool_input"]
        else { return nil }
        transcript = URL(fileURLWithPath: path)
        self.toolName = toolName
        self.toolInput = toolInput
        offset = (try? transcript.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
        // Claude Code writes the call to the transcript before it asks.
        let earlier = read(from: offset > Self.lookBack ? offset - Self.lookBack : 0)
        for line in earlier.lines { _ = isResult(line) }
    }

    /// True once a result for the call has been written since the hook started.
    func hasHappened() -> Bool {
        let fresh = read(from: offset)
        offset += UInt64(fresh.complete)
        return fresh.lines.contains { isResult($0) }
    }

    /// Whole lines from `start` on; a line still being written waits for the next look.
    private func read(from start: UInt64) -> (lines: [Data], complete: Int) {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return ([], 0) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n"))
        else { return ([], 0) }
        let complete = data[data.startIndex...lastNewline]
        return (complete.split(separator: UInt8(ascii: "\n")).map { Data($0) }, complete.count)
    }

    /// Notes a matching call on an assistant line; true for a result answering one.
    private func isResult(_ line: Data) -> Bool {
        guard line.range(of: Data("tool_use".utf8)) != nil,  // in both "tool_use" blocks and "tool_use_id"
              let json = try? JSONValue(parsing: String(decoding: line, as: UTF8.self)),
              let blocks = json["message"]?["content"]?.array
        else { return false }
        for block in blocks {
            if block["type"]?.string == "tool_use", block["name"]?.string == toolName,
               let id = block["id"]?.string, block["input"].map({ $0.isEquivalent(to: toolInput) }) == true {
                callIds.insert(id)
            }
            if block["type"]?.string == "tool_result", let id = block["tool_use_id"]?.string, callIds.contains(id) {
                return true
            }
        }
        return false
    }
}
