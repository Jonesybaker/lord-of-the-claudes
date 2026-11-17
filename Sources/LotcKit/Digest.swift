import Foundation

/// What a session is doing, in three short lines, written by the observer each time Claude stops.
public struct Digest: Codable, Equatable, Sendable {
    /// What the session is for.
    public var goal: String
    /// Where the work has got to.
    public var state: String
    /// What it needs from the user; nil when nothing.
    public var blockedOn: String?
    public var at: Date

    public init(goal: String, state: String, blockedOn: String? = nil, at: Date) {
        self.goal = goal
        self.state = state
        self.blockedOn = blockedOn
        self.at = at
    }

    public static let historyLimit = 20

    /// `history` with `latest` as its last entry: added when the state line has moved on, else in place of
    /// the last one, so the history is a list of distinct steps. Only the newest `historyLimit` are kept.
    public static func history(_ history: [Digest], adding latest: Digest) -> [Digest] {
        var result = history
        if result.last?.state == latest.state { result.removeLast() }
        result.append(latest)
        return Array(result.suffix(historyLimit))
    }
}
