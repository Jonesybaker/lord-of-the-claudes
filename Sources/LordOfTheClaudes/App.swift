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

/// Catches key presses in the panel before the search field's text editor swallows them
/// (it treats the arrow keys as cursor movement).
final class PanelKeys {
    var handler: ((UInt16) -> Bool)?

    init() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window?.className.contains("MenuBarExtraWindow") == true,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  self?.handler?(event.keyCode) == true
            else { return event }
            return nil
        }
    }
}
