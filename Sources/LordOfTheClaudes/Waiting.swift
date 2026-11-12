import Foundation

/// Whether a session is waiting for the user: it finished work they have not seen it finish.
enum Waiting {
    /// A status change this soon after the process started is Claude Code starting up, not work finishing.
    static let startUp: TimeInterval = 10

    /// - Parameters:
    ///   - statusChangedAt: when its status last changed, e.g. when Claude stopped working.
    ///   - startedAt: when its process started; a resumed session starts a new one.
    ///   - seenAt: last time its tab was in front of the user, or it was reopened; nil until first seen.
    ///   - lastPromptAt: the user's last prompt to it. Prompting it is seeing it.
    static func needsYou(status: String, statusChangedAt: Date, startedAt: Date?, seenAt: Date?, lastPromptAt: Date?) -> Bool {
        guard status != "busy", let seenAt else { return false }
        if let startedAt, statusChangedAt.timeIntervalSince(startedAt) < startUp { return false }
        return statusChangedAt > max(seenAt, lastPromptAt ?? .distantPast)
    }
}
