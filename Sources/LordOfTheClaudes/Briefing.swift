import Foundation

extension Store {
    /// Every running session by window, in tab order, for the overseer: where it is, what it is, and its
    /// digest, or without one its last prompt. A stand-in until the observer writes the fuller one.
    func digestBriefing() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func ago(_ date: Date) -> String { shortAge(date) == "now" ? "just now" : shortAge(date) + " ago" }
        func describe(_ row: Row, tab: String) -> [String] {
            let cwd = row.cwd.hasPrefix(home) ? "~" + row.cwd.dropFirst(home.count) : row.cwd
            let status = row.status == "busy" ? "working"
                : row.needsYou ? "waiting for you, finished \(ago(row.statusSince ?? row.lastInteraction))" : "idle"
            var lines = ["- \(tab)\"\(row.title)\" in \(cwd): \(status)" + (row.isLord ? ", lord of its window" : "")]
            if let digest = row.digest {
                lines.append("  goal: \(digest.goal)")
                lines.append("  state: \(digest.state)")
                if let blockedOn = digest.blockedOn { lines.append("  blocked on: \(blockedOn)") }
            } else if let prompt = row.prompts.last {
                let text = prompt.text.split(whereSeparator: \.isNewline).joined(separator: " ")
                lines.append("  last prompt, \(ago(prompt.date)): \(text.prefix(300))")
            }
            return lines
        }

        var out: [String] = []
        for group in groups {
            out.append("Group \"\(group.name)\":")
            for row in group.rows { out += describe(row, tab: "tab \(row.tab ?? 0) ") }
        }
        let grouped = Set(groups.flatMap { $0.rows.map(\.id) })
        let other = rows.filter { $0.isLive && !grouped.contains($0.id) }
        if !other.isEmpty {
            out.append("Group \"Other\" (tabs that could not be found):")
            for row in other { out += describe(row, tab: "") }
        }
        return out.isEmpty ? "No Claude Code sessions are open." : out.joined(separator: "\n")
    }
}
