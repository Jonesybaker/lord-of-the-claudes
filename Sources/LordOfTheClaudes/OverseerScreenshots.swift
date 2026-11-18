import AppKit
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

    /// A question answered from the briefing.
    @MainActor
    static func questionChat() -> OverseerChat {
        OverseerChat(demo: [
            OverseerMessage(role: .user, text: "what's going on with the holiday stuff?"),
            OverseerMessage(role: .overseer, text: """
                Two sessions are on it. [Cottage for the half-term break](session:Home/1) has four dog-friendly \
                cottages under £900 shortlisted. [Coach to Old Trafford](session:Home/2) found two coaches for \
                Saturday; the 06:40 is cheapest. Neither is waiting for you.
                """),
        ])
    }

    /// A question answered from the briefing, then a prompt routed to a session, waiting for Send.
    @MainActor
    static func sendChat(places: [SessionPlace]) -> OverseerChat {
        let messages = [
            OverseerMessage(role: .user, text: "where did the passkeys work get to?"),
            OverseerMessage(role: .overseer, text: """
                [Migrate auth to passkeys](session:Shop/1) has registration working and the sign-in page built. \
                3 of 41 browser tests fail on Safari 16, and it is waiting for your call: drop Safari 16 or add a polyfill.
                """),
            OverseerMessage(role: .user, text: "tell the invoice one to add a test for an invoice with 21 lines"),
            OverseerMessage(role: .overseer, text: "I would send this to [Invoice PDF rounding bug](session:Platform/2)."),
        ]
        let card = RoutingCard.make(.send(targets: [ProposedTarget(group: "Platform", tab: 2, title: "Invoice PDF rounding bug")],
                                          prompt: "add a test for an invoice with 21 lines, then fix the rounding"),
                                    places: places)
        return OverseerChat(demo: messages, card: card)
    }

    /// A screenshot pasted into a message, then a prompt proposed with it, waiting for Send.
    @MainActor
    static func imageChat(places: [SessionPlace]) -> OverseerChat {
        let images = demoInvoice().map { [$0] } ?? []
        let messages = [
            OverseerMessage(role: .user, text: "another one a penny out, send it to the invoice session", attachments: images),
            OverseerMessage(role: .overseer, text: "I would send this to [Invoice PDF rounding bug](session:Platform/2), with your screenshot."),
        ]
        var card = RoutingCard.make(.send(targets: [ProposedTarget(group: "Platform", tab: 2, title: "Invoice PDF rounding bug")],
                                          prompt: "another invoice with the VAT a penny out, see the attached screenshot"),
                                    places: places)
        card.images = images
        return OverseerChat(demo: messages, card: card)
    }

    /// A made-up invoice with its VAT ringed, drawn here so no real screen is shown.
    private static func demoInvoice() -> AttachedImage? {
        let size = NSSize(width: 720, height: 440)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(white: 0.9, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 672, height: 392), xRadius: 10, yRadius: 10).fill()
        func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false, right: Bool = false,
                  colour: NSColor = NSColor(white: 0.15, alpha: 1)) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: colour,
            ]
            let width = (string as NSString).size(withAttributes: attributes).width
            (string as NSString).draw(at: NSPoint(x: right ? x - width : x, y: y), withAttributes: attributes)
        }
        text("Invoice INV-2041", x: 60, y: 340, size: 44, bold: true)
        text("United Kit Shop · 22 lines", x: 60, y: 304, size: 24, colour: .gray)
        let rows: [(String, String, CGFloat)] = [("Subtotal", "£1,049.95", 236), ("VAT at 20%", "£210.00", 176), ("Total", "£1,259.95", 116)]
        for (label, amount, y) in rows {
            text(label, x: 60, y: y, size: 34, bold: label == "Total")
            text(amount, x: 660, y: y, size: 34, bold: label == "Total", right: true)
        }
        NSColor(white: 0.8, alpha: 1).setFill()
        NSRect(x: 60, y: 162, width: 600, height: 2).fill()
        NSColor.systemRed.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 486, y: 164, width: 196, height: 64))
        ring.lineWidth = 6
        ring.stroke()
        text("should be £209.99", x: 660, y: 54, size: 30, bold: true, right: true, colour: .systemRed)
        NSGraphicsContext.restoreGraphicsState()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LordOfTheClaudes-screenshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("invoice.png")
        guard let png = bitmap.representation(using: .png, properties: [:]), (try? png.write(to: file)) != nil else { return nil }
        return AttachedImage(path: file.path)
    }

    /// A send already confirmed, then a question the briefing cannot answer: a tab to look at, waiting for Go.
    @MainActor
    static func goToChat(places: [SessionPlace]) -> OverseerChat {
        let messages = [
            OverseerMessage(role: .user, text: "tell the invoice one to add a test for an invoice with 21 lines"),
            OverseerMessage(role: .overseer, text: "I would send this to [Invoice PDF rounding bug](session:Platform/2)."),
            OverseerMessage(role: .note, text: "Sent to Platform, tab 2 (Invoice PDF rounding bug)."),
            OverseerMessage(role: .user, text: "take me to the checkout one, I want to see the fix"),
            OverseerMessage(role: .overseer, text: """
                [Fix flaky checkout test](session:Shop/2) has a fix drafted for the race between the basket cache \
                and the price service. The diff is in its tab, so that is the place to look.
                """),
        ]
        let card = RoutingCard.make(.goTo(targets: [ProposedTarget(group: "Shop", tab: 2, title: "Fix flaky checkout test")]),
                                    places: places)
        return OverseerChat(demo: messages, card: card)
    }
}
