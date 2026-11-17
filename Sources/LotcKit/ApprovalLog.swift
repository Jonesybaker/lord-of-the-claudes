import Foundation

/// One request a rule approved, as the Auto-approve page and `lotc approvals` show it.
public struct ApprovalLogEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var at: Date
    /// The session's title and place, or its directory when the app does not track it.
    public var session: String
    public var cwd: String
    public var tool: String
    /// What was approved, in full: the query, URL or command.
    public var summary: String
    /// The rule's id; see `AutoApproveRule`.
    public var rule: String

    public init(id: UUID = UUID(), at: Date = Date(), session: String, cwd: String, tool: String, summary: String, rule: String) {
        self.id = id
        self.at = at
        self.session = session
        self.cwd = cwd
        self.tool = tool
        self.summary = summary
        self.rule = rule
    }

    public var ruleTitle: String { AutoApproveRule(rawValue: rule)?.title ?? rule }
}

/// The log keeps the last `cap` approvals, oldest first.
public enum ApprovalLog {
    public static let cap = 500
    /// A summary longer than this is cut, so one huge command cannot swell the file.
    public static let summaryCap = 8000

    public static func adding(_ entry: ApprovalLogEntry, to entries: [ApprovalLogEntry]) -> [ApprovalLogEntry] {
        var entry = entry
        if entry.summary.count > summaryCap { entry.summary = String(entry.summary.prefix(summaryCap)) + "…" }
        return Array((entries + [entry]).suffix(cap))
    }

    public static func count(_ entries: [ApprovalLogEntry], since: Date) -> Int {
        entries.reversed().prefix { $0.at >= since }.count
    }

    public static func decode(_ data: Data?) -> [ApprovalLogEntry] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Array(((try? decoder.decode([ApprovalLogEntry].self, from: data)) ?? []).suffix(cap))
    }

    public static func encode(_ entries: [ApprovalLogEntry]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(entries)
    }
}

/// What `lotc approvals` gets from the app: the switches and the log, newest first.
public struct AutoApproveReport: Codable, Equatable, Sendable {
    public var settings: AutoApproveSettings
    public var log: [ApprovalLogEntry]

    public init(settings: AutoApproveSettings, log: [ApprovalLogEntry]) {
        self.settings = settings
        self.log = log
    }
}
