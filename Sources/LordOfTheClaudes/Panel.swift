import AppKit
import Carbon.HIToolbox

/// Opens and closes the menu bar panel from code. SwiftUI's MenuBarExtra has no API for this,
/// so it clicks the status item's own button, which keeps SwiftUI's open/closed state in step.
@MainActor
enum Panel {
    private static var statusButton: NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            let selector = Selector(("statusItem"))
            guard window.responds(to: selector),
                  let item = window.perform(selector)?.takeUnretainedValue() as? NSStatusItem
            else { continue }
            return item.button
        }
        return nil
    }

    static var isOpen: Bool {
        NSApp.windows.contains { $0.isVisible && $0.className.contains("MenuBarExtraWindow") }
    }

    static func toggle() {
        NSApp.activate(ignoringOtherApps: true)  // so the search field takes the keyboard
        statusButton?.performClick(nil)
        // The panel only receives keys once it is the key window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.windows.first { $0.isVisible && $0.className.contains("MenuBarExtraWindow") }?.makeKey()
        }
    }

    static func close() {
        if isOpen { statusButton?.performClick(nil) }
    }
}

/// A system-wide hotkey via Carbon, which needs no Accessibility permission.
enum HotKey {
    static let display = "⌃⌥C"
    private static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        guard !Sandbox.isOn else { return }  // the installed app has it
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x434C_4F56), id: 1)  // 'CLOV'
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("Lord of the Claudes: could not register hotkey (\(status))") }
    }
}
