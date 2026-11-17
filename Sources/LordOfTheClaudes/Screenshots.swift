import AppKit
import LotcKit
import SwiftUI

/// Renders the panel off screen for the README, from made-up sessions so no real work is shown.
@MainActor
enum Screenshots {
    static func render(into dir: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        PanelHeights.screenOverride = 1400
        let store = Store(demoRows: withDemoDigests(demoRows()), groupNames: ["w1": "Shop", "w2": "Platform", "w3": "Docs"],
                          collapsed: ["w3"])
        let shots = [
            Shot(name: "panel-dark", appearance: .darkAqua),
            Shot(name: "panel-light", appearance: .aqua),
            Shot(name: "panel-prompts", appearance: .darkAqua, expanded: ["2"], historyOpen: ["2"]),
            Shot(name: "panel-reply", appearance: .aqua, expanded: ["1"],
                 drafts: ["1": "log the random seed on every run, then run it 50 times"]),
            Shot(name: "panel-broadcast", appearance: .darkAqua,
                 broadcast: BroadcastDraft(windowId: "w2", text: "rebase on main and run the tests", confirming: true)),
            Shot(name: "panel-overseer", appearance: .darkAqua, chat: demoChat(places: store.overseerPlaces)),
        ]
        var windows: [(String, NSWindow)] = []
        for shot in shots {
            // Never the real chat: its conversation is the user's own.
            let panel = PanelView(store: store, chat: shot.chat ?? OverseerChat(demo: []), expanded: shot.expanded,
                                  drafts: shot.drafts, broadcast: shot.broadcast, historyOpen: shot.historyOpen)
            let host = NSHostingView(rootView: panel
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .environment(\.colorScheme, shot.appearance == .darkAqua ? .dark : .light))
            host.appearance = NSAppearance(named: shot.appearance)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: shot.appearance)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000))  // off screen
            window.orderFrontRegardless()
            windows.append((shot.name, window))
        }
        // The list sizes itself a layout pass after it appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for (name, window) in windows {
                guard let view = window.contentView else { continue }
                window.setContentSize(view.fittingSize)
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent(name + ".png"))
            }
            exit(0)
        }
        app.run()
    }

    /// One PNG: the panel in a theme, with whatever it starts with open.
    private struct Shot {
        let name: String
        let appearance: NSAppearance.Name
        var expanded: Set<String> = []
        var drafts: [String: String] = [:]
        var broadcast: BroadcastDraft?
        var chat: OverseerChat?
        var historyOpen: Set<String> = []
    }

    /// Three made-up Ghostty windows: "Shop" (w1, its lord the passkeys session), "Platform" (w2)
    /// and "Docs" (w3, folded away with one session waiting).
    private static func demoRows() -> [Row] {
        func ago(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }
        /// Steps oldest first, each (minutes ago, state); the goal and what it is blocked on go with the last.
        func digests(_ goal: String, _ steps: [(Double, String)], blockedOn: String? = nil) -> [Digest] {
            steps.enumerated().map { index, step in
                Digest(goal: goal, state: step.1, blockedOn: index == steps.count - 1 ? blockedOn : nil, at: ago(step.0))
            }
        }
        func row(_ id: String, _ title: String, _ cwd: String, status: String?, last: Double,
                 needsYou: Bool = false, prompts: [(Double, String)], ticket: String? = nil,
                 window: String? = nil, tab: Int? = nil, lord: Bool = false, digests: [Digest] = []) -> Row {
            Row(id: id, title: title, cwd: NSHomeDirectory() + "/Projects/" + cwd, status: status,
                statusSince: status == nil ? nil : ago(max(last - 2, 1)), lastInteraction: ago(last),
                needsYou: needsYou, prompts: prompts.map { (ago($0.0), $0.1) },
                ticket: ticket.flatMap(URL.init(string:)), windowId: window, tab: tab, isLord: lord,
                digest: digests.last, digestHistory: digests)
        }
        return [
            row("1", "Fix flaky checkout test", "shop-api", status: "idle", last: 14, needsYou: true,
                prompts: [(14, "the checkout test fails one run in ten, find out why")],
                ticket: "https://example.atlassian.net/browse/SHOP-482", window: "w1", tab: 2,
                digests: digests("Find why the checkout test fails one run in ten",
                                 [(12, "Traced to a basket built with an unseeded random discount")],
                                 blockedOn: "Whether to log the seed on every run")),
            row("2", "Migrate auth to passkeys", "shop-web", status: "idle", last: 38, needsYou: true,
                prompts: [(95, "plan the move from passwords to passkeys, keep magic links as the fallback"),
                          (61, "go with option 2, start with the registration ceremony"),
                          (38, "now the sign-in page, and run the browser tests")],
                window: "w1", tab: 1, lord: true,
                digests: digests("Move sign-in from passwords to passkeys, magic links kept as fallback",
                                 [(88, "Compared three passkey libraries; recommends option 2"),
                                  (52, "Registration ceremony built and unit tested"),
                                  (36, "Sign-in page done; 3 of 41 browser tests fail on Safari 16")],
                                 blockedOn: "Your call: drop Safari 16 or add a polyfill")),
            row("3", "Upgrade to Postgres 17", "infra", status: "busy", last: 3,
                prompts: [(3, "rehearse the upgrade against last night's snapshot and time it")],
                window: "w2", tab: 1,
                digests: digests("Rehearse the Postgres 17 upgrade and time it",
                                 [(20, "Snapshot restored to a scratch instance"), (2, "pg_upgrade running, 40 minutes in")])),
            row("4", "Invoice PDF rounding bug", "billing", status: "busy", last: 9,
                prompts: [(9, "VAT is a penny out on invoices with more than 20 lines")],
                ticket: "https://example.zendesk.com/agent/tickets/4922", window: "w2", tab: 2),
            row("5", "Release notes for 2.4", "shop-web", status: "idle", last: 190,
                prompts: [(190, "draft release notes from the merged PRs since v2.3.0")],
                window: "w1", tab: 3,
                digests: digests("Release notes for 2.4 from the merged PRs", [(185, "Draft written to docs/releases/2.4.md")])),
            row("6", "Tidy the Terraform modules", "infra", status: "idle", last: 26 * 60,
                prompts: [(26 * 60, "list every module nothing references any more")],
                window: "w2", tab: 3,
                digests: digests("Find Terraform modules nothing uses", [(26 * 60 - 5, "Six unused modules listed, none removed yet")])),
            row("7", "Spike: search with pg_trgm", "shop-api", status: "idle", last: 4 * 24 * 60,
                prompts: [(4 * 24 * 60, "is trigram search fast enough for 2m products?")],
                window: "w1", tab: 4,
                digests: digests("Test trigram search on 2m products",
                                 [(4 * 24 * 60 - 20, "Answers in 40 ms at the 95th percentile; write-up done")])),
            row("10", "Fix broken links in the guides", "docs", status: "idle", last: 22, needsYou: true,
                prompts: [(22, "find every broken link in the guides and fix them")],
                window: "w3", tab: 1,
                digests: digests("Fix the broken links in the guides", [(20, "Fixed 23 links; 2 point to retired pages")],
                                 blockedOn: "Where the two retired pages should point")),
            row("11", "Screenshots for the 2.4 guide", "docs", status: "busy", last: 6,
                prompts: [(6, "retake the screenshots in the 2.4 guide")],
                window: "w3", tab: 2),
            row("8", "Onboarding email copy", "marketing", status: nil, last: 2 * 24 * 60,
                prompts: [(2 * 24 * 60, "shorten the welcome email to five lines")],
                digests: digests("Cut the welcome email to five lines",
                                 [(2 * 24 * 60 - 10, "Five-line version written and sent for review")])),
            row("9", "Dependabot backlog", "shop-web", status: nil, last: 6 * 24 * 60,
                prompts: [(6 * 24 * 60, "merge the safe ones, list the rest")],
                digests: digests("Clear the Dependabot backlog",
                                 [(6 * 24 * 60 - 30, "Merged 9 safe updates; 3 need a major-version look")])),
        ]
    }
}
