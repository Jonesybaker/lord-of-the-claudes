import Foundation
import LotcKit

/// The digests as plain text for a model to read: `lotc digest`, and the overseer's view of every window.
enum DigestBriefing {
    struct Group {
        let name: String
        let rows: [Row]
    }

    static func text(_ groups: [Group], now: Date = Date(),
                     home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let groups = groups.filter { !$0.rows.isEmpty }
        let rows = groups.flatMap(\.rows)
        guard !rows.isEmpty else { return "No Claude Code sessions are open." }
        let waiting = rows.filter(\.needsYou).count
        let summary = "\(count(rows.count, "session")) in \(count(groups.count, "window")), \(waiting) waiting for you."
        return ([summary] + groups.map { group in
            (["", "## " + group.name] + group.rows.flatMap { session($0, now: now, home: home) }).joined(separator: "\n")
        }).joined(separator: "\n")
    }

    private static func session(_ row: Row, now: Date, home: String) -> [String] {
        let status = [row.status == "busy" ? "working" : (row.status ?? "closed"),
                      row.needsYou ? "waiting for you" : nil, row.isLord ? "lord" : nil].compactMap { $0 }
        let place = row.tab.map { "tab \($0)" } ?? "no tab"
        let cwd = row.cwd.hasPrefix(home + "/") ? "~" + row.cwd.dropFirst(home.count) : row.cwd
        var lines = ["\(place): \(row.title) [\(status.joined(separator: ", "))]", "  cwd: \(cwd)"]
        guard let digest = row.digest else { return lines + ["  no digest yet"] }
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
