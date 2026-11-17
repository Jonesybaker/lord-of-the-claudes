import Foundation

/// How the sidebar groups the running sessions.
enum Grouping: String, CaseIterable {
    /// By what the work is about: the observer's topic, else the project folder.
    case topic
    /// By Ghostty window.
    case window
}

/// A heading in the sidebar and the running sessions under it: a Ghostty window, a topic, or "Other".
struct SidebarGroup: Identifiable {
    enum Kind: Equatable {
        case window(String)
        case topic(String)
        /// Sessions whose tab cannot be found, in window grouping.
        case other
    }

    let kind: Kind
    let name: String
    /// Its place in the sidebar, from 1: Cmd+1 to Cmd+9 jump to it.
    let number: Int
    /// Every running session in it, whatever the filter.
    let all: [Row]
    /// The ones matching the filter: waiting first, then most recent prompt.
    let shown: [Row]
    /// Folded away by the user. Nil when it cannot fold: "Other", or the only group.
    let collapsed: Bool?

    var id: String {
        switch kind {
        case .window(let id): "window:" + id
        case .topic(let name): "topic:" + name.lowercased()
        case .other: "other"
        }
    }

    var windowId: String? { if case .window(let id) = kind { id } else { nil } }
    var topic: String? { if case .topic(let name) = kind { name } else { nil } }
    var waitingCount: Int { all.filter(\.needsYou).count }
    /// The rows under its header: none while folded, unless a filter is looking inside.
    func onScreen(filtering: Bool) -> [Row] { collapsed == true && !filtering ? [] : shown }
}

/// Builds the sidebar's groups from the running sessions.
enum SidebarGroups {
    /// A window as the store names it, its sessions in tab order, and whether it is folded.
    struct Window {
        let id: String
        let name: String
        let rows: [Row]
        let collapsed: Bool
    }

    /// Ghostty windows in window order, then "Other" for sessions whose tab cannot be found.
    static func byWindow(_ windows: [Window], running: [Row], matches: (Row, String) -> Bool) -> [SidebarGroup] {
        var found = windows.map { (kind: SidebarGroup.Kind.window($0.id), name: $0.name, all: $0.rows, collapsed: $0.collapsed) }
        let grouped = Set(windows.map(\.id))
        let other = running.filter { row in row.windowId.map { !grouped.contains($0) } ?? true }
        if !other.isEmpty { found.append((kind: .other, name: "Other", all: other, collapsed: false)) }
        return numbered(found, matches: matches)
    }

    /// One group per topic. Groups with a session waiting for you come first, then the most recently prompted.
    /// `running` is in the store's order, waiting first then most recent, which each group keeps.
    static func byTopic(running: [Row], collapsed: Set<String>, matches: (Row, String) -> Bool) -> [SidebarGroup] {
        var order: [String] = []
        var members: [String: [Row]] = [:]
        for row in running {
            let key = row.topicName.lowercased()
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(row)
        }
        let groups = order.map { key in
            let rows = members[key]!
            return (kind: SidebarGroup.Kind.topic(rows[0].topicName), name: rows[0].topicName, all: rows,
                    collapsed: collapsed.contains(key))
        }
        let ranked = groups.sorted { a, b in
            let waiting = (a.all.contains(where: \.needsYou), b.all.contains(where: \.needsYou))
            if waiting.0 != waiting.1 { return waiting.0 }
            let latest = (a.all.map(\.lastInteraction).max()!, b.all.map(\.lastInteraction).max()!)
            if latest.0 != latest.1 { return latest.0 > latest.1 }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return numbered(ranked, matches: matches)
    }

    private static func numbered(_ found: [(kind: SidebarGroup.Kind, name: String, all: [Row], collapsed: Bool)],
                                 matches: (Row, String) -> Bool) -> [SidebarGroup] {
        // A lone group has nothing to make room for.
        let canFold = found.count > 1
        return found.enumerated().map { index, group in
            SidebarGroup(kind: group.kind, name: group.name, number: index + 1, all: group.all,
                         shown: group.all.filter { matches($0, group.kind == .other ? "" : group.name) },
                         collapsed: canFold && group.kind != .other ? group.collapsed : nil)
        }
    }

    /// A closed session stays findable by what it did: its digests are searched too.
    static func matches(_ row: Row, query: String, groupName: String = "") -> Bool {
        guard !query.isEmpty else { return true }
        let digests = row.digestHistory + (row.digest.map { [$0] } ?? [])
        let words = [row.title, row.cwd, groupName, row.topicName] + digests.flatMap { [$0.goal, $0.state, $0.blockedOn ?? ""] }
        return words.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// Where the selection lands when the sidebar jumps between groups or hides rows. Rows are ids in screen order.
enum SectionJump {
    /// The first row of the section `delta` sections on from the one holding `current`, stopping at the ends.
    static func target(from current: String?, by delta: Int, in sections: [[String]]) -> String? {
        guard !sections.isEmpty else { return nil }
        let here = sections.firstIndex { section in section.contains { $0 == current } } ?? 0
        return sections[min(max(here + delta, 0), sections.count - 1)].first
    }

    /// The row to select in place of `current` once `hiding` goes out of sight: the next one left, else the one before.
    static func survivor(of current: String, hiding: Set<String>, in order: [String]) -> String? {
        guard let at = order.firstIndex(of: current) else { return nil }
        return order[at...].first { !hiding.contains($0) } ?? order[..<at].last { !hiding.contains($0) }
    }
}

/// A prompt being written to every session in a group.
struct BroadcastDraft: Equatable {
    let groupId: String
    var text = "" { didSet { if text != oldValue { confirming = false } } }
    /// Return was pressed once and the sessions it goes to are on screen: the next Return sends.
    var confirming = false
    /// Who gets it, fixed when the confirm shows, so it goes to exactly the sessions listed.
    var recipients: [String] = []
    var sending = false
}

/// The group whose name is being edited, and the name typed so far.
struct GroupRename: Equatable {
    let groupId: String
    var name: String
}
