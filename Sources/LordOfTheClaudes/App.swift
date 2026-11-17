import AppKit
import SwiftUI

/// The app: a menu bar icon and a window it shows and hides. It starts with the window hidden.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var window: MainWindow!
    private var statusItem: StatusItem!
    private var menu: MainMenu!
    /// Lets a script show or hide the window: `pkill -USR1 -x LordOfTheClaudes`.
    private var toggleSignal: DispatchSourceSignal?

    static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.make()
        store = Store()
        let model = WindowModel(store: store, chat: .shared)
        window = MainWindow(model: model)
        statusItem = StatusItem(store: store, toggle: { [weak self] in self?.window.toggle() },
                                show: { [weak self] in self?.window.show() })
        menu = MainMenu(model: model, window: window)
        menu.install()
        HotKey.register { [weak self] in self?.window.toggle() }

        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.window.toggle() } }
        source.resume()
        toggleSignal = source
    }

    /// A click on the Dock icon, or opening the app again from Finder.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// "now", "12m", "23h", "5d", "2w".
func shortAge(_ date: Date, now: Date = Date()) -> String {
    let age = now.timeIntervalSince(date)
    switch age {
    case ..<60: return "now"
    case ..<3600: return "\(Int(age / 60))m"
    case ..<86400: return "\(Int(age / 3600))h"
    case ..<(14 * 86400): return "\(Int(age / 86400))d"
    default: return "\(Int(age / (7 * 86400)))w"
    }
}

extension Color {
    /// Orange for "waiting for you", dark enough to read as text on the light window.
    static let waiting = adaptive(light: (0.63, 0.31, 0), dark: (1, 0.62, 0.04))
    /// Gold for the lord's crown, at 3:1 or better against the window in both themes.
    static let lord = adaptive(light: (0.54, 0.37, 0), dark: (1, 0.8, 0.2))

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}
