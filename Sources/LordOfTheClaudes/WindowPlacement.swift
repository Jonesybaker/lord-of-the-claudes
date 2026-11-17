import AppKit

/// Where the main window goes: where it was last, kept on a screen that is still there, else centred.
struct WindowPlacement {
    static let defaultSize = NSSize(width: 1100, height: 760)
    /// Narrow enough to tile to a third of a 1920-point screen, where the sidebar becomes an overlay.
    static let minimumSize = NSSize(width: 600, height: 480)
    static let key = "MainWindowFrame"

    let defaults: UserDefaults

    var saved: NSRect? {
        defaults.string(forKey: Self.key).map(NSRectFromString).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
    }

    func save(_ frame: NSRect) { defaults.set(NSStringFromRect(frame), forKey: Self.key) }

    /// The frame to open at, on screens whose visible frames are `screens`, the main one first.
    func frame(screens: [NSRect]) -> NSRect { Self.place(saved: saved, screens: screens) }

    /// The saved frame if its title bar is on a screen, moved and sized to fit that screen; else the
    /// default size centred on the main screen.
    static func place(saved: NSRect?, screens: [NSRect]) -> NSRect {
        guard let main = screens.first else { return saved ?? NSRect(origin: .zero, size: defaultSize) }
        if let saved, let screen = screens.first(where: { titleBar(of: saved).intersects($0) }) {
            return fit(saved, in: screen)
        }
        let size = NSSize(width: min(defaultSize.width, main.width), height: min(defaultSize.height, main.height))
        return NSRect(x: main.midX - size.width / 2, y: main.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The strip the user drags by. A window whose title bar is off every screen cannot be moved back.
    private static func titleBar(of frame: NSRect) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
    }

    private static func fit(_ frame: NSRect, in screen: NSRect) -> NSRect {
        let width = min(max(frame.width, minimumSize.width), screen.width)
        let height = min(max(frame.height, minimumSize.height), screen.height)
        let x = min(max(frame.minX, screen.minX), screen.maxX - width)
        let y = min(max(frame.minY, screen.minY), screen.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
