import AppKit
import SwiftUI

/// The main window. Closing it hides it and the app goes back to the menu bar alone; while it shows,
/// the app is in the Dock and Cmd+Tab like any other.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    nonisolated static let identifier = NSUserInterfaceItemIdentifier("lotc-main")

    let window: NSWindow
    private let model: WindowModel
    private let placement: WindowPlacement
    /// Closing a full-screen window leaves full screen first, then hides.
    private var hideAfterFullScreen = false
    /// The app that was in front before this one, to hand the keyboard back to on hiding.
    private var previousApp: NSRunningApplication?
    private var activations: NSObjectProtocol?

    init(model: WindowModel, defaults: UserDefaults = .standard) {
        self.model = model
        placement = WindowPlacement(defaults: defaults)
        window = Self.makeWindow()
        super.init()
        let host = NSHostingController(rootView: MainView(model: model))
        host.sizingOptions = []
        window.contentViewController = host
        window.setFrame(placement.frame(screens: Self.screens), display: false)
        window.delegate = self
        // Cmd+H and the Dock hide it without `hide()`; a report arriving meanwhile is unread.
        for (name, visible) in [(NSApplication.didHideNotification, false), (NSApplication.didUnhideNotification, true)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.windowVisible = visible && self.window.isVisible && !self.window.isMiniaturized
                }
            }
        }
        activations = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.previousApp = app }
        }
    }

    /// A standard titled window: it moves, resizes, tiles and goes full screen.
    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: WindowPlacement.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.identifier = identifier
        window.title = "Lord of the Claudes"
        window.contentMinSize = WindowPlacement.minimumSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        return window
    }

    /// Visible frames, the main screen first.
    private static var screens: [NSRect] {
        let main = NSScreen.main.map { [$0] } ?? []
        return (main + NSScreen.screens.filter { $0 != NSScreen.main }).map(\.visibleFrame)
    }

    var isFrontmost: Bool { NSApp.isActive && !NSApp.isHidden && window.isVisible && window.isKeyWindow }

    /// The hotkey and the menu bar icon: in front, it hides; otherwise it comes to the front.
    func toggle() { if isFrontmost { hide() } else { show() } }

    func show() {
        let wasHidden = !window.isVisible || NSApp.isHidden || window.isMiniaturized
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.windowShown(fromHidden: wasHidden)
    }

    func hide() {
        if window.styleMask.contains(.fullScreen) {
            hideAfterFullScreen = true
            window.toggleFullScreen(nil)
            return
        }
        placement.save(window.frame)
        window.orderOut(nil)
        model.windowHidden()
        NSApp.setActivationPolicy(.accessory)
        if NSApp.isActive, let previousApp, !previousApp.isTerminated { previousApp.activate() }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard hideAfterFullScreen else { return }
        hideAfterFullScreen = false
        hide()
    }

    func windowDidMiniaturize(_ notification: Notification) { model.windowHidden() }
    func windowDidDeminiaturize(_ notification: Notification) { model.windowVisible = !NSApp.isHidden }

    func windowDidMove(_ notification: Notification) { remember() }
    func windowDidEndLiveResize(_ notification: Notification) { remember() }

    private func remember() {
        guard window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
        placement.save(window.frame)
    }
}
