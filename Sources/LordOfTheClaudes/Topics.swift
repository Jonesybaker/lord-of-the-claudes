import Foundation

/// What the observer is told about topics when it sums a session up, so it reuses labels rather than minting new ones.
struct TopicContext: Equatable, Sendable {
    /// The session's topic so far, if the observer has given it one.
    var current: String?
    /// Every topic given to a session, commonest first.
    var inUse: [String]

    static let none = TopicContext(current: nil, inUse: [])
}

/// Topic labels: how a raw one is tidied, which existing one it means, and when a session moves to another.
enum Topics {
    static let maxWords = 3
    static let maxLength = 32

    /// One to three words, first letter capitalised, no quotes or trailing full stop. Nil for "none" or nothing.
    static func clean(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`*.,;:!?()[]"))
        let words = trimmed.split(whereSeparator: \.isWhitespace).prefix(maxWords)
        var label = words.joined(separator: " ")
        guard !label.isEmpty, !["none", "n/a", "unknown", "nothing"].contains(label.lowercased()) else { return nil }
        if label.count > maxLength { label = String(label.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// Before any digest, a session is filed under its project folder.
    static func folder(of cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? "Sessions" : name
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// The label as the sidebar already spells it: a renamed topic's new name, else an existing topic
    /// that differs only in case, else the label itself.
    static func canonical(_ label: String, inUse: [String], aliases: [String: String]) -> String {
        let named = aliases[label.lowercased()] ?? label
        return inUse.first { same($0, named) } ?? named
    }

    /// The session's topic after a digest. A hand-set topic never changes. A first topic is taken at once;
    /// a change needs the observer to propose the same new topic twice running, so one odd digest moves nothing.
    static func next(current: String?, pinned: Bool, proposed: String?, previous: String?,
                     inUse: [String], aliases: [String: String]) -> String? {
        guard !pinned, let proposed = proposed.flatMap(clean) else { return current }
        let label = canonical(proposed, inUse: inUse, aliases: aliases)
        guard let current else { return label }
        if same(label, current) { return current }
        let before = previous.flatMap(clean).map { canonical($0, inUse: inUse, aliases: aliases) }
        return before.map { same($0, label) } == true ? label : current
    }

    /// Distinct labels, commonest first, then alphabetical.
    static func ranked(_ labels: [String]) -> [String] {
        var counts: [String: (label: String, count: Int)] = [:]
        for label in labels {
            let key = label.lowercased()
            counts[key] = (counts[key]?.label ?? label, (counts[key]?.count ?? 0) + 1)
        }
        return counts.values.sorted { ($1.count, $0.label) < ($0.count, $1.label) }.map(\.label)
    }
}
