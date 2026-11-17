import AppKit

/// The Dock and Cmd+Tab icon while the window shows: a gold crown on deep blue, drawn rather than shipped.
enum AppIcon {
    static func make() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 50, dy: 50), xRadius: 90, yRadius: 90)
            NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.27, blue: 0.62, alpha: 1),
                       ending: NSColor(srgbRed: 0.09, green: 0.1, blue: 0.27, alpha: 1))?.draw(in: tile, angle: -90)
            let gold = NSImage.SymbolConfiguration(pointSize: 200, weight: .semibold)
                .applying(.init(paletteColors: [NSColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1)]))
            guard let crown = NSImage(systemSymbolName: "crown.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(gold)
            else { return true }
            crown.draw(in: NSRect(x: rect.midX - crown.size.width / 2, y: rect.midY - crown.size.height / 2,
                                  width: crown.size.width, height: crown.size.height))
            return true
        }
    }
}
