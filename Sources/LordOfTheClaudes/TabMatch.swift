import Foundation

/// Finds the Ghostty tab each running session is in. Ghostty does not expose a tab's process, so this
/// goes by what it does show: the title Claude Code gives the tab, and the tab's working directory.
/// Never guesses: a session is left without a tab rather than given one that may be another's.
enum TabMatch {
    struct Session {
        let id: String
        let title: String
        let cwd: String
    }

    /// Session id to its tab.
    /// 1. By title. Sessions sharing a title are told apart by directory.
    /// 2. A session no tab is titled after (new, so its tab still reads "Claude Code") takes the one
    ///    Claude tab in its directory that is titled after no session, if it is the only such session there.
    static func pair(_ sessions: [Session], with terminals: [GhosttyTerminal]) -> [String: GhosttyTerminal] {
        let tabs = terminals.filter(\.looksLikeClaude)
        var pairs: [String: GhosttyTerminal] = [:]

        for (title, named) in Dictionary(grouping: sessions, by: \.title) {
            let titled = tabs.filter { $0.sessionTitle == title }
            let byTitle = oneToOne(named, titled) { _, _ in true }
            let left = named.filter { byTitle[$0.id] == nil }
            let leftTabs = titled.filter { tab in !byTitle.values.contains { $0.id == tab.id } }
            let byDirectory = oneToOne(left, leftTabs) { samePath($0.cwd, $1.cwd) }
            pairs.merge(byTitle) { a, _ in a }
            pairs.merge(byDirectory) { a, _ in a }
        }

        let tabTitles = Set(tabs.map(\.sessionTitle))
        let sessionTitles = Set(sessions.map(\.title))
        let untitled = sessions.filter { !tabTitles.contains($0.title) }
        let unclaimed = tabs.filter { !sessionTitles.contains($0.sessionTitle) }
        pairs.merge(oneToOne(untitled, unclaimed) { samePath($0.cwd, $1.cwd) }) { a, _ in a }
        return pairs
    }

    /// Pairs each session with the one tab that fits it, where that tab fits no other session.
    private static func oneToOne(_ sessions: [Session], _ tabs: [GhosttyTerminal],
                                 fits: (Session, GhosttyTerminal) -> Bool) -> [String: GhosttyTerminal] {
        var pairs: [String: GhosttyTerminal] = [:]
        for session in sessions {
            let candidates = tabs.filter { fits(session, $0) }
            guard candidates.count == 1,
                  sessions.filter({ fits($0, candidates[0]) }).count == 1
            else { continue }
            pairs[session.id] = candidates[0]
        }
        return pairs
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }
}
