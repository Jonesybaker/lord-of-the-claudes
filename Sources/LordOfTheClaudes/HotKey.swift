import AppKit
import Carbon.HIToolbox

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
