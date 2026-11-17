import AppKit
import Carbon.HIToolbox

/// Where the keyboard is in the main window. Nil means no text field: the sidebar's list has it.
enum MainField: Hashable {
    /// The message to the overseer: where the keyboard starts.
    case composer
    /// The prompt on the overseer's routing card.
    case proposal
    case filter
    case reply(sessionId: String)
    case broadcast(groupId: String)
    case rename(groupId: String)
}

/// What a key press in the main window does. MainView carries it out.
enum MainKey: Equatable {
    /// The focused field, or AppKit, has it.
    case passThrough
    /// Used up with no effect, so an empty field does not take a stray Return.
    case nothing
    case send
    case sendReply
    /// Cmd+V with an image on the clipboard, in a field that takes images.
    case pasteImages
    case newLine
    case confirmCard
    case escape
    case focusComposer
    case focusFilter
    case toggleSidebar
    case reply
    case move(Int)
    case jumpSection(Int)
    case group(Int)
    case showDetail
    case showChat
    case goToTab
    /// Typing with the list focused goes to the overseer.
    case type(String)
}

/// Decides what each key press means, from where the keyboard is. A pure function, so it is tested.
enum MainKeys {
    struct Context: Equatable {
        var focus: MainField?
        var composerEmpty = true
        /// The sidebar is on screen, docked or as an overlay.
        var sidebarVisible = true
        /// A proposal is on screen that Return can act on.
        var cardWaiting = false
        /// An input method is part way through a character, so Return is its.
        var composing = false
        /// What is on the clipboard is images, not text.
        var imagesToPaste = false
    }

    /// The fields an image can be pasted or dropped into: they send to the overseer or a session.
    static func takesImages(_ field: MainField?) -> Bool {
        switch field {
        case .composer, .proposal, .reply: true
        default: false
        }
    }

    static func route(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?, in context: Context) -> MainKey {
        let modifiers = modifiers.intersection([.command, .control, .option, .shift])
        let isReturn = keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter
        let typed = characters?.lowercased()

        if keyCode == kVK_Escape && modifiers.isEmpty { return .escape }
        if modifiers == .command {
            switch (keyCode, typed) {
            case (kVK_ANSI_0, _): return .toggleSidebar
            case (_, "l"): return .focusComposer
            case (_, "f"): return .focusFilter
            case (_, "r"): return .reply
            case (_, "v") where context.imagesToPaste && takesImages(context.focus): return .pasteImages
            default: break
            }
        }
        if isReturn && context.composing { return .passThrough }

        switch context.focus {
        case .composer:
            if isReturn && modifiers.isEmpty {
                if !context.composerEmpty { return .send }
                if context.cardWaiting { return .confirmCard }
                return context.sidebarVisible ? .goToTab : .nothing
            }
            if isReturn && modifiers == .shift { return .newLine }
            if modifiers == .command { return listShortcut(keyCode) }
            guard modifiers.isEmpty, context.composerEmpty, context.sidebarVisible else { return .passThrough }
            switch keyCode {
            case kVK_UpArrow: return .move(-1)
            case kVK_DownArrow: return .move(1)
            case kVK_RightArrow: return .showDetail
            default: return .passThrough
            }
        case .proposal:
            if isReturn && modifiers.isEmpty { return .confirmCard }
            return isReturn && modifiers == .shift ? .newLine : .passThrough
        case .reply:
            if isReturn && modifiers.isEmpty { return .sendReply }
            return isReturn && modifiers == .shift ? .newLine : .passThrough
        case .broadcast, .rename:
            return .passThrough
        case .filter:
            if modifiers == .command { return listShortcut(keyCode) }
            guard modifiers.isEmpty else { return .passThrough }
            switch keyCode {
            case kVK_UpArrow: return .move(-1)
            case kVK_DownArrow: return .move(1)
            case kVK_Return, kVK_ANSI_KeypadEnter: return .goToTab
            case kVK_RightArrow: return .showDetail
            default: return .passThrough
            }
        case nil:
            if modifiers == .command { return listShortcut(keyCode) }
            if modifiers.isEmpty {
                switch keyCode {
                case kVK_UpArrow: return .move(-1)
                case kVK_DownArrow: return .move(1)
                case kVK_Return, kVK_ANSI_KeypadEnter: return .goToTab
                case kVK_RightArrow: return .showDetail
                case kVK_LeftArrow: return .showChat
                default: break
                }
            }
            if modifiers.subtracting(.shift).isEmpty, let characters, isPrintable(characters) { return .type(characters) }
            return .passThrough
        }
    }

    /// Cmd+Up and Cmd+Down between groups, Cmd+1 to Cmd+9 to one.
    private static func listShortcut(_ keyCode: Int) -> MainKey {
        switch keyCode {
        case kVK_UpArrow: return .jumpSection(-1)
        case kVK_DownArrow: return .jumpSection(1)
        default: return numberKeys[keyCode].map(MainKey.group) ?? .passThrough
        }
    }

    /// Cmd+1 to Cmd+9 by key position, whatever the keyboard layout.
    static let numberKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    /// Letters, digits, punctuation and spaces; not arrows, function keys or control characters.
    private static func isPrintable(_ characters: String) -> Bool {
        !characters.isEmpty && characters.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }
}

/// Sees key presses in the main window before its text fields do, as they would swallow the arrows and Return.
final class MainKeyMonitor {
    /// Returns true if it used the key, which then goes no further.
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window?.identifier == MainWindow.identifier, self?.handler?(event) == true else { return event }
            return nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
