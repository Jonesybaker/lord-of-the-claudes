import AppKit
import LotcKit
import SwiftUI

/// Renders the main window off screen for the README, from made-up sessions so no real work is shown.
@MainActor
enum Screenshots {
    nonisolated static let size = NSSize(width: 1040, height: 700)

    /// `only`: the names of the shots to take; empty takes them all. A window drawn alone draws as the active one.
    static func render(into dir: URL, only: Set<String> = []) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rows = withDemoDigests(demoRows())
        let names = ["w1": "Shop", "w2": "Platform", "w3": "Docs", "w4": "Home"]
        let shots = [
            Shot(name: "window-dark", appearance: .darkAqua),
            Shot(name: "window-light", appearance: .aqua, grouping: .window, chat: { _ in questionChat() }),
            Shot(name: "window-overseer", appearance: .darkAqua, chat: { sendChat(places: $0) }),
            Shot(name: "window-goto", appearance: .aqua, chat: { goToChat(places: $0) }),
            Shot(name: "window-session", appearance: .darkAqua, pane: .session("2")),
            Shot(name: "window-reply", appearance: .aqua, pane: .session("1"),
                 drafts: ["1": "log the random seed on every run, then run it 50 times"]),
            Shot(name: "window-broadcast", appearance: .darkAqua,
                 broadcast: BroadcastDraft(groupId: "topic:checkout", text: "rebase on main and run the tests",
                                           confirming: true, recipients: ["1", "4"])),
            Shot(name: "window-narrow", appearance: .aqua, width: 640, overlay: true),
            Shot(name: "window-auto-approve", appearance: .aqua, pane: .autoApprove),
            Shot(name: "window-auto-approve-dark", appearance: .darkAqua, pane: .autoApprove),
        ]
        var windows: [(String, NSWindow)] = []
        for shot in shots where only.isEmpty || only.contains(shot.name) {
            // Never the real chat or the user's settings: a store and chat of made-up data, remembering nothing.
            let store = Store(demoRows: rows, groupNames: names, collapsedTopics: ["Tax"], approvals: demoApprovals())
            let model = WindowModel(store: store, chat: shot.chat?(store.overseerPlaces) ?? OverseerChat(demo: []), defaults: nil)
            model.grouping = shot.grouping
            model.pane = shot.pane
            if case .session(let id) = shot.pane { model.selection = id }
            model.drafts = shot.drafts
            model.broadcast = shot.broadcast
            model.overlayOpen = shot.overlay
            let window = MainWindow.makeWindow()
            window.appearance = NSAppearance(named: shot.appearance)
            let scheme: ColorScheme = shot.appearance == .darkAqua ? .dark : .light
            let host = NSHostingController(rootView: MainView(model: model).environment(\.colorScheme, scheme))
            host.sizingOptions = []
            window.contentViewController = host
            window.setContentSize(NSSize(width: shot.width, height: size.height))
            window.setFrameOrigin(NSPoint(x: -8000, y: -8000))  // off screen
            window.orderFrontRegardless()
            windows.append((shot.name, window))
        }
        // SwiftUI lays out and scrolls a pass or two after the window appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for (name, window) in windows {
                // The frame view holds the title bar as well as the content.
                guard let view = window.contentView?.superview else { continue }
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

    /// One PNG: the window in a theme, with whatever it starts with open.
    private struct Shot {
        let name: String
        let appearance: NSAppearance.Name
        var grouping: Grouping = .topic
        var pane: MainPane = .chat
        var drafts: [String: String] = [:]
        var broadcast: BroadcastDraft?
        var chat: ((_ places: [SessionPlace]) -> OverseerChat)?
        var width: CGFloat = Screenshots.size.width
        var overlay = false
    }

    /// Three rules on, one directory kept private, and a morning of made-up approvals.
    private static func demoApprovals() -> AutoApprovals {
        func ago(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }
        let home = NSHomeDirectory() + "/Projects/"
        let entries: [(Double, String, String, String, String, AutoApproveRule)] = [
            (26 * 60, "Coach to Old Trafford (Home, tab 2)", "home", "WebSearch",
             "Manchester United home fixtures December", .webSearch),
            (190, "Release notes for 2.4 (Shop, tab 3)", "shop-web", "Bash",
             "curl -sI https://github.com/example-shop/shop-web/releases", .shellGet),
            (75, "Cottage for the half-term break (Home, tab 1)", "home", "WebFetch",
             "https://www.example-cottages.co.uk/devon/dog-friendly?sleeps=4", .publicFetch),
            (48, "Migrate auth to passkeys (Shop, tab 1) · subagent Explore", "shop-web", "WebFetch",
             "https://webauthn.guide/", .publicFetch),
            (31, "Fix broken links in the guides (Docs, tab 1)", "docs", "Bash",
             "curl -s -o /dev/null -w '%{http_code}' https://docs.example.com/guides/returns", .shellGet),
            (14, "Invoice PDF rounding bug (Platform, tab 2)", "billing", "WebSearch",
             "VAT rounding per line or per invoice UK", .webSearch),
            (9, "Upgrade to Postgres 17 (Platform, tab 1)", "infra", "WebFetch",
             "https://www.postgresql.org/docs/17/upgrading.html", .publicFetch),
            (6, "Fix flaky checkout test (Shop, tab 2) · subagent Explore", "shop-api", "WebSearch",
             "seeded random numbers in jest tests", .webSearch),
            (2, "Coach to Old Trafford (Home, tab 2)", "home", "WebSearch",
             "coach Leeds to Old Trafford Saturday 06:40", .webSearch),
        ]
        let log = entries.map { minutes, session, folder, tool, summary, rule in
            ApprovalLogEntry(at: ago(minutes), session: session, cwd: home + folder, tool: tool, summary: summary, rule: rule.rawValue)
        }
        return AutoApprovals(demo: AutoApproveSettings(isOn: true, excludedDirectories: ["~/Projects/finances"]), log: log)
    }

    /// Four made-up Ghostty windows: "Shop" (w1, its lord the passkeys session), "Platform" (w2), "Docs" (w3)
    /// and "Home" (w4, unrelated odds and ends, which topics sort out).
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
                 window: String? = nil, tab: Int? = nil, lord: Bool = false, digests: [Digest] = [],
                 topic: String? = nil, pinned: Bool = false) -> Row {
            Row(id: id, title: title, cwd: NSHomeDirectory() + "/Projects/" + cwd, status: status,
                statusSince: status == nil ? nil : ago(max(last - 2, 1)), lastInteraction: ago(last),
                needsYou: needsYou, prompts: prompts.map { (ago($0.0), $0.1) },
                ticket: ticket.flatMap(URL.init(string:)), windowId: window, tab: tab, isLord: lord,
                digest: digests.last, digestHistory: digests, topic: topic, topicPinned: pinned)
        }
        return [
            row("1", "Fix flaky checkout test", "shop-api", status: "idle", last: 14, needsYou: true,
                prompts: [(14, "the checkout test fails one run in ten, find out why")],
                ticket: "https://example.atlassian.net/browse/SHOP-482", window: "w1", tab: 2,
                digests: digests("Find why the checkout test fails one run in ten",
                                 [(12, "Traced to a basket built with an unseeded random discount")],
                                 blockedOn: "Whether to log the seed on every run"),
                topic: "Checkout"),
            row("2", "Migrate auth to passkeys", "shop-web", status: "idle", last: 38, needsYou: true,
                prompts: [(95, "plan the move from passwords to passkeys, keep magic links as the fallback"),
                          (61, "go with option 2, start with the registration ceremony"),
                          (38, "now the sign-in page, and run the browser tests")],
                window: "w1", tab: 1, lord: true,
                digests: digests("Move sign-in from passwords to passkeys, magic links kept as fallback",
                                 [(88, "Compared three passkey libraries; recommends option 2"),
                                  (52, "Registration ceremony built and unit tested"),
                                  (36, "Sign-in page done; 3 of 41 browser tests fail on Safari 16")],
                                 blockedOn: "Your call: drop Safari 16 or add a polyfill"),
                topic: "Sign-in"),
            row("3", "Upgrade to Postgres 17", "infra", status: "busy", last: 3,
                prompts: [(3, "rehearse the upgrade against last night's snapshot and time it")],
                window: "w2", tab: 1,
                digests: digests("Rehearse the Postgres 17 upgrade and time it",
                                 [(20, "Snapshot restored to a scratch instance"), (2, "pg_upgrade running, 40 minutes in")]),
                topic: "Database"),
            row("4", "Invoice PDF rounding bug", "billing", status: "busy", last: 9,
                prompts: [(9, "VAT is a penny out on invoices with more than 20 lines")],
                ticket: "https://example.zendesk.com/agent/tickets/4922", window: "w2", tab: 2, topic: "Checkout"),
            row("5", "Release notes for 2.4", "shop-web", status: "idle", last: 190,
                prompts: [(190, "draft release notes from the merged PRs since v2.3.0")],
                window: "w1", tab: 3,
                digests: digests("Release notes for 2.4 from the merged PRs", [(185, "Draft written to docs/releases/2.4.md")]),
                topic: "Release 2.4"),
            row("6", "Tidy the Terraform modules", "infra", status: "idle", last: 26 * 60,
                prompts: [(26 * 60, "list every module nothing references any more")],
                window: "w2", tab: 3),
            row("7", "Spike: search with pg_trgm", "shop-api", status: "idle", last: 4 * 24 * 60,
                prompts: [(4 * 24 * 60, "is trigram search fast enough for 2m products?")],
                window: "w1", tab: 4,
                digests: digests("Test trigram search on 2m products",
                                 [(4 * 24 * 60 - 20, "Answers in 40 ms at the 95th percentile; write-up done")]),
                topic: "Database"),
            row("10", "Fix broken links in the guides", "docs", status: "idle", last: 22, needsYou: true,
                prompts: [(22, "find every broken link in the guides and fix them")],
                window: "w3", tab: 1,
                digests: digests("Fix the broken links in the guides", [(20, "Fixed 23 links; 2 point to retired pages")],
                                 blockedOn: "Where the two retired pages should point"),
                topic: "Guides"),
            row("11", "Screenshots for the 2.4 guide", "docs", status: "busy", last: 6,
                prompts: [(6, "retake the screenshots in the 2.4 guide")],
                window: "w3", tab: 2, topic: "Release 2.4"),
            row("12", "Cottage for the half-term break", "home", status: "idle", last: 55,
                prompts: [(55, "find a dog-friendly cottage in Devon for half term, under £900")],
                window: "w4", tab: 1,
                digests: digests("Shortlist dog-friendly cottages in Devon for half term",
                                 [(50, "Four cottages under £900 shortlisted with links")]),
                topic: "Holiday"),
            row("13", "Coach to Old Trafford", "home", status: "idle", last: 140,
                prompts: [(140, "coach times from Leeds to Old Trafford for the Saturday match")],
                window: "w4", tab: 2,
                digests: digests("Coach times to Old Trafford for Saturday", [(135, "Two coaches found; the 06:40 is cheapest")]),
                topic: "Holiday"),
            row("14", "Working from home allowance", "home", status: "idle", last: 300,
                prompts: [(300, "can I claim the working from home allowance as well as my own costs?")],
                window: "w4", tab: 3,
                digests: digests("Check what working from home costs can be claimed", [(296, "Explained the flat rate against actual costs")]),
                topic: "Tax", pinned: true),
            row("15", "Mortgage paperwork", "finances", status: "idle", last: 400,
                prompts: [(400, "list the documents the lender still wants")],
                window: "w4", tab: 4,
                digests: digests("List the documents the lender wants", [(395, "Three documents still to find")])),
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
