import Foundation
import LotcKit

/// `lotc approvals` as text for a person.
enum ApprovalsText {
    /// Newest first: when, which rule, which session, then what was approved on its own line.
    static func log(_ entries: [ApprovalLogEntry], home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        guard !entries.isEmpty else { return "Nothing has been auto-approved." }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "dd/MM HH:mm"
        return entries.map { entry in
            let summary = entry.summary.split(whereSeparator: \.isNewline).joined(separator: " ")
            return "\(formatter.string(from: entry.at))  \(entry.ruleTitle)  \(entry.session)\n    \(summary.prefix(200))"
        }.joined(separator: "\n")
    }

    static func status(_ settings: AutoApproveSettings) -> String {
        var lines = ["Auto-approve: " + (settings.isOn ? "on" : "off, so no rule approves anything")]
        let width = AutoApproveRule.allCases.map(\.title.count).max() ?? 0
        for rule in AutoApproveRule.allCases {
            let state = settings.isOn(rule) ? "on " : "off"
            lines.append("  \(state)  \(rule.title.padding(toLength: width, withPad: " ", startingAt: 0))  \(rule.summary)")
        }
        lines.append(settings.excludedDirectories.isEmpty
            ? "Excluded directories: none"
            : "Excluded directories:\n" + settings.excludedDirectories.map { "  " + $0 }.joined(separator: "\n"))
        lines.append("Change these on the Auto-approve page in Lord of the Claudes. No lotc command switches them.")
        return lines.joined(separator: "\n")
    }
}
