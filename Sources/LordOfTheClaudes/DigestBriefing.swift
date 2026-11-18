import Foundation
import LotcKit

/// The digests as plain text for a model to read: `lotc digest`, and the overseer's view of every window.
/// Grouped by window, as tab numbers count within a window; each session names its topic.
enum DigestBriefing {
    struct Group {
        let name: String
        let rows: [Row]
    }

    static func text(_ groups: [Group], now: Date = Date(),
                     home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        // A model reads this, so private sessions are only counted.
        let hidden = groups.flatMap(\.rows).filter(\.isPrivate).count
        let groups = groups.map { Group(name: $0.name, rows: $0.rows.filter { !$0.isPrivate }) }.filter { !$0.rows.isEmpty }
        let rows = groups.flatMap(\.rows)
        let unseen = hidden == 0 ? [] : [
            "\(count(hidden, "private session")) \(hidden == 1 ? "is" : "are") open that you cannot see. If the developer "
                + "asks for a session you cannot find, say it may be one of those and that they can pick it in the sidebar.",
        ]
        guard !rows.isEmpty else {
            return ([hidden == 0 ? "No Claude Code sessions are open." : "No Claude Code sessions you can see are open."] + unseen)
                .joined(separator: "\n")
        }
        let waiting = rows.filter(\.needsYou).count
        let summary = "\(count(rows.count, "session")) in \(count(groups.count, "window")), \(waiting) waiting for you."
        return ([summary] + unseen + groups.map { group in
            (["", "## " + group.name] + group.rows.flatMap { session($0, now: now, home: home) }).joined(separator: "\n")
        }).joined(separator: "\n")
    }

    private static func session(_ row: Row, now: Date, home: String) -> [String] {
        let status = [row.status == "busy" ? "working" : (row.status ?? "closed"),
                      row.needsYou ? "waiting for you" : nil, row.isLord ? "lord" : nil].compactMap { $0 }
        let place = row.tab.map { "tab \($0)" } ?? "no tab"
        let cwd = row.cwd.hasPrefix(home + "/") ? "~" + row.cwd.dropFirst(home.count) : row.cwd
        var lines = ["\(place): \(row.title) [\(status.joined(separator: ", "))]", "  cwd: \(cwd)", "  topic: \(row.topicName)"]
        guard let digest = row.digest else {
            // Digests arrive at a session's next stop; until then its last prompt says most.
            guard let prompt = row.prompts.last else { return lines + ["  no digest yet"] }
            let text = prompt.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return lines + ["  no digest yet; last prompt, \(ago(prompt.date, now: now)): \(text.prefix(300))"]
        }
        lines += [
            "  goal: \(digest.goal)",
            "  state: \(digest.state)",
            "  blocked on: \(digest.blockedOn ?? "nothing")",
            "  summarised: \(ago(digest.at, now: now))",
        ]
        return lines
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let age = shortAge(date, now: now)
        return age == "now" ? "just now" : age + " ago"
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}
