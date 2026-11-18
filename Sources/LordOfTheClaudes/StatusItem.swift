import AppKit
import Combine

/// The menu bar icon: the count of sessions, "2/7" when two are waiting for you, and a badge for a report
/// from the overseer not yet read. A click shows or hides the window; a right-click offers Open and Quit.
@MainActor
final class StatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: Store
    private let chat: OverseerChat
    private let toggle: () -> Void
    private let show: () -> Void
    private var watch: AnyCancellable?

    init(store: Store, chat: OverseerChat, toggle: @escaping () -> Void, show: @escaping () -> Void) {
        self.store = store
        self.chat = chat
        self.toggle = toggle
        self.show = show
        super.init()
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        update()
        // objectWillChange fires before the change, so read the store a beat later.
        watch = store.objectWillChange.merge(with: chat.objectWillChange).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
    }

    private var symbol: String {
        if store.needsYouCount > 0 { return "bell.badge" }
        if chat.unread { return "message.badge" }
        return store.pending.isEmpty ? "rectangle.stack" : "rectangle.stack.badge.plus"
    }

    private func update() {
        guard let button = item.button else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "bell.badge", accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image
        let waiting = store.needsYouCount
        button.title = waiting > 0 ? " \(waiting)/\(store.liveCount)" : " \(store.liveCount)"
        button.setAccessibilityLabel("Lord of the Claudes: \(store.liveCount) sessions"
                                     + (waiting > 0 ? ", \(waiting) waiting for you" : "")
                                     + (chat.unread ? ", a report from the overseer to read" : ""))
    }

    @objc private func clicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp, let button = item.button else {
            toggle()
            return
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Lord of the Claudes", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Lord of the Claudes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        // A menu set on the item opens under it on the next click, here a pretend one; then it goes again.
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    @objc private func open() { show() }
}
