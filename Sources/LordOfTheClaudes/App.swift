import Carbon.HIToolbox
import SwiftUI


struct MenuBarApp: App {
    @StateObject private var store = Store()

    private var icon: String {
        if store.needsYouCount > 0 { return "bell.badge" }
        return store.pending.isEmpty ? "rectangle.stack" : "rectangle.stack.badge.plus"
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            Image(systemName: icon)
            // "2/20": two of twenty sessions are waiting for you.
            Text(store.needsYouCount > 0 ? "\(store.needsYouCount)/\(store.liveCount)" : "\(store.liveCount)")
        }
        .menuBarExtraStyle(.window)
    }
}

/// "now", "12m", "23h", "5d", "2w".
func shortAge(_ date: Date) -> String {
    let age = Date().timeIntervalSince(date)
    switch age {
    case ..<60: return "now"
    case ..<3600: return "\(Int(age / 60))m"
    case ..<86400: return "\(Int(age / 3600))h"
    case ..<(14 * 86400): return "\(Int(age / 86400))d"
    default: return "\(Int(age / (7 * 86400)))w"
    }
}

extension Color {
    /// Orange for "waiting for you", dark enough to read as text on the light panel.
    static let waiting = adaptive(light: (0.63, 0.31, 0), dark: (1, 0.62, 0.04))
    /// Gold for the lord's crown, at 3:1 or better against the panel in both themes.
    static let lord = adaptive(light: (0.54, 0.37, 0), dark: (1, 0.8, 0.2))

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

/// Catches key presses in the panel before the search field's text editor swallows them
/// (it treats the arrow keys as cursor movement).
final class PanelKeys {
    /// Returns true if it used the key, which then goes no further.
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window?.className.contains("MenuBarExtraWindow") == true,
                  self?.handler?(event) == true
            else { return event }
            return nil
        }
    }

    // SwiftUI builds a throwaway PanelKeys each time it re-creates the panel's view; each must remove its monitor.
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
