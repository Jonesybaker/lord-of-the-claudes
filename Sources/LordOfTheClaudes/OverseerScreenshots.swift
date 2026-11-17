import Foundation
import LotcKit

/// The overseer's part of the README screenshots: made-up digests and a made-up conversation.
extension Screenshots {
    /// What the observer might have written about the sessions waiting or working in `demoRows`.
    static func withDemoDigests(_ rows: [Row]) -> [Row] {
        let digests: [String: (goal: String, state: String, blockedOn: String?)] = [
            "1": ("Find why the checkout test fails one run in ten",
                  "Found a race between the basket cache and the price service. A fix is drafted",
                  "Wants a yes to commit the fix and quarantine the old test"),
            "2": ("Move sign-in from passwords to passkeys",
                  "Registration works. The sign-in page is built",
                  "Check the new sign-in page before it runs the browser tests"),
            "10": ("Fix every broken link in the guides",
                   "Fixed 31 of 33",
                   "Two links point at pages that no longer exist: drop them or redirect?"),
            "3": ("Rehearse the Postgres 17 upgrade", "Restoring last night's snapshot", nil),
        ]
        return rows.map { row in
            guard let digest = digests[row.id] else { return row }
            var row = row
            row.digest = Digest(goal: digest.goal, state: digest.state, blockedOn: digest.blockedOn, at: Date())
            return row
        }
    }

    /// A question answered from the briefing, then a prompt routed to a session, waiting for Send.
    @MainActor
    static func demoChat(places: [SessionPlace]) -> OverseerChat {
        let messages = [
            OverseerMessage(role: .user, text: "where did the passkeys work get to?"),
            OverseerMessage(role: .overseer, text: """
                [Migrate auth to passkeys](session:Shop/1) has registration working and the sign-in page built. \
                It is waiting for you to check that page before it runs the browser tests.
                """),
            OverseerMessage(role: .user, text: "tell the invoice one to add a test for an invoice with 21 lines"),
            OverseerMessage(role: .overseer, text: "I would send this to [Invoice PDF rounding bug](session:Platform/2)."),
        ]
        let card = RoutingCard.make(.send(targets: [ProposedTarget(group: "Platform", tab: 2, title: "Invoice PDF rounding bug")],
                                          prompt: "add a test for an invoice with 21 lines, then fix the rounding"),
                                    places: places)
        return OverseerChat(demo: messages, card: card)
    }
}
