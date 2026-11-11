import Foundation

/// Works out the Zendesk or Jira ticket a session is about, from its title or the links pasted into it.
/// The sites come from ~/Library/Application Support/LordOfTheClaudes/tickets.json:
///   {"zendesk": "https://example.zendesk.com/agent/tickets/", "jira": "https://example.atlassian.net/browse/"}
/// Without the file, only links pasted into a session are recognised.
enum Tickets {
    private struct Sites: Decodable {
        var zendesk: String?
        var jira: String?
    }

    private static let sites: Sites = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LordOfTheClaudes/tickets.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Sites.self, from: data)
        else { return Sites() }
        return decoded
    }()

    private static let pastedLink = try! Regex(#"https://[a-z0-9.-]+(?:\.zendesk\.com/agent/tickets/\d+|/browse/[A-Z][A-Z0-9]+-\d+)"#)
    private static let jiraKey = try! Regex(#"\b([A-Z]{2,10})-(\d+)\b"#)
    /// "Zendesk ticket 4922", "ticket #4922", or "{Org} - 4922".
    private static let zendeskNumber = try! Regex(#"(?i)(?:\b(?:zendesk|ticket)\D{0,10}|^.+ - )(\d{3,7})\b"#)
    /// Things shaped like a Jira key that are not one.
    private static let notProjects: Set<Substring> = ["UTF", "SHA", "ISO", "AES"]

    static func link(title: String) -> URL? {
        if let jira = sites.jira, let match = title.firstMatch(of: jiraKey),
           let project = match.output[1].substring, let number = match.output[2].substring,
           !notProjects.contains(project) {
            return URL(string: jira + project + "-" + number)
        }
        if let zendesk = sites.zendesk, let match = title.firstMatch(of: zendeskNumber),
           let number = match.output[1].substring {
            return URL(string: zendesk + number)
        }
        return nil
    }

    static func firstLink(in text: String) -> URL? {
        text.firstMatch(of: pastedLink).flatMap { URL(string: String(text[$0.range])) }
    }
}
