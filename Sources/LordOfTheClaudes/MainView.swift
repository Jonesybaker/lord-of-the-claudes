import AppKit
import SwiftUI

/// The main window's content: the sidebar beside the chat or a session. Below `WindowModel.compactWidth`
/// the sidebar opens over the main area instead. Every key press comes through here first (MainKeys).
struct MainView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var store: Store
    @ObservedObject var chat: OverseerChat
    @FocusState private var focus: MainField?
    @State private var keys = MainKeyMonitor()
    @State private var dragStartWidth: CGFloat?

    static let headerHeight: CGFloat = 40

    init(model: WindowModel) {
        self.model = model
        store = model.store
        chat = model.chat
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < WindowModel.compactWidth
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if !compact && model.sidebarShown {
                        sidebar.frame(width: model.sidebarWidth)
                        divider
                    }
                    main.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if compact && model.overlayOpen {
                    Color.black.opacity(0.25)
                        .onTapGesture { model.overlayOpen = false }
                        .accessibilityHidden(true)
                    sidebar
                        .frame(width: min(model.sidebarWidth, geometry.size.width - 60))
                        .shadow(radius: 12)
                        .transition(.move(edge: .leading))
                }
            }
            .onAppear { model.compact = compact }
            .onChange(of: compact) { _, compact in
                model.compact = compact
                if !compact { model.overlayOpen = false }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.15), value: model.overlayOpen)
        .onAppear {
            keys.handler = handleKey
            setFocus(.composer)
        }
        .onReceive(model.focusRequests) { setFocus($0) }
        .onReceive(model.menuPastes) {
            // A field that takes no images pastes as usual.
            if !perform(.pasteImages, editor: nil) { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
        }
        .onChange(of: focus) { old, _ in
            // Clicking away from a group's name field cancels the rename, as Esc does.
            if case .rename(let id) = old, model.renaming?.groupId == id { model.renaming = nil }
        }
        .alert("New topic", isPresented: Binding(get: { model.namingTopicFor != nil },
                                                 set: { if !$0 { model.namingTopicFor = nil } })) {
            TextField("Topic name", text: $model.newTopicName)
            Button("Move") { model.saveNewTopic() }
            Button("Cancel", role: .cancel) { model.newTopicName = "" }
        } message: {
            Text("One to three words. The observer never moves a session you have placed.")
        }
    }

    private var sidebar: some View {
        Sidebar(model: model, store: store, chat: chat, focus: $focus)
    }

    /// Drag to resize the sidebar.
    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStartWidth ?? model.sidebarWidth
                        dragStartWidth = start
                        model.setSidebarWidth(start + drag.translation.width, final: false)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        model.setSidebarWidth(model.sidebarWidth, final: true)
                    }))
            .accessibilityHidden(true)
    }

    private var main: some View {
        VStack(spacing: 0) {
            if store.automationBlocked {
                notice("Cannot talk to Ghostty. Allow Lord of the Claudes under System Settings > Privacy & Security > Automation.")
            }
            if !store.pending.isEmpty { pendingBanner }
            if let row = model.shownSession {
                SessionDetail(row: row, model: model, focus: $focus)
            } else if model.pane == .autoApprove {
                AutoApprovePage(model: model, approvals: store.approvals)
            } else {
                ChatView(chat: chat, model: model, focus: $focus)
            }
        }
    }

    private var pendingBanner: some View {
        HStack {
            if store.restoring {
                ProgressView().controlSize(.small)
                Text("Reopening \(store.pending.count) sessions...")
            } else {
                Text("\(store.pending.count) sessions were open when Ghostty last closed.")
                Spacer()
                Button("Reopen all") { store.restorePending() }
                Button("Dismiss") { store.dismissPending() }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.15))
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.2))
    }

    // MARK: Focus

    /// Where the keyboard goes when it leaves a field: the composer beside the chat, else the list.
    private var home: MainField? { model.pane == .chat ? .composer : nil }

    /// Moves the keyboard once the field exists. Into a message box, the cursor goes to the end, as
    /// macOS selects all of a field it focuses and the next key would replace a draft.
    private func setFocus(_ field: MainField?) {
        DispatchQueue.main.async {
            focus = field
            let window = NSApp.windows.first { $0.identifier == MainWindow.identifier }
            if field == nil { window?.makeFirstResponder(nil) }
            DispatchQueue.main.async {
                guard field == .composer || field.map(Self.isReply) == true,
                      let editor = window?.firstResponder as? NSTextView
                else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }

    private static func isReply(_ field: MainField) -> Bool { if case .reply = field { true } else { false } }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let editor = event.window?.firstResponder as? NSTextView
        let command = event.modifierFlags.contains(.command)
        let pasting = command && event.charactersIgnoringModifiers?.lowercased() == "v"
        let context = MainKeys.Context(
            focus: focus, composerEmpty: !chat.hasDraft, sidebarVisible: model.sidebarVisible,
            cardWaiting: chat.card.map { $0.canSend && !$0.sending } == true, composing: editor?.hasMarkedText() == true,
            imagesToPaste: pasting && PastedImages.holdsImages(NSPasteboard.general))
        let key = MainKeys.route(keyCode: Int(event.keyCode), modifiers: event.modifierFlags,
                                 characters: command ? event.charactersIgnoringModifiers : event.characters, in: context)
        return perform(key, editor: editor)
    }

    private func perform(_ key: MainKey, editor: NSTextView?) -> Bool {
        switch key {
        case .passThrough:
            return false
        case .nothing:
            break
        case .send:
            chat.submit(to: store)
        case .sendReply:
            if case .reply(let id) = focus, let row = store.rows.first(where: { $0.id == id }) { model.sendReply(to: row) }
        case .pasteImages:
            guard let images = imagesOfFocusedField, let sources = PastedImages.sources(from: .general) else { return false }
            ImageIntake.attach(sources, to: images)
        case .newLine:
            editor?.insertNewlineIgnoringFieldEditor(nil)
        case .confirmCard:
            Task {
                await chat.confirm(using: store, fromKeyboard: true)
                if chat.card == nil { setFocus(.composer) }
            }
        case .escape:
            escape()
        case .focusComposer:
            model.showChat()
        case .focusFilter:
            model.revealSidebar()
            setFocus(.filter)
        case .toggleSidebar:
            model.toggleSidebar()
            if model.sidebarVisible { setFocus(nil) } else if inSidebar { setFocus(home) }
        case .reply:
            model.startReply()
        case .move(let delta):
            model.moveSelection(delta)
        case .jumpSection(let delta):
            model.jumpSection(by: delta)
        case .group(let number):
            model.jumpToGroup(number)
        case .showDetail:
            model.showDetail()
            if focus == .composer, model.pane != .chat { setFocus(nil) }
        case .showChat:
            if model.pane != .chat { model.showChat() }
        case .goToTab:
            if let row = model.selectedRow { model.goTo(row) }
        case .type(let characters):
            chat.draft += characters
            model.showChat()
        }
        return true
    }

    /// Where a pasted image goes: the message being written where the keyboard is.
    private var imagesOfFocusedField: Binding<[AttachedImage]>? {
        switch focus {
        case .composer:
            return $chat.draftImages
        case .proposal:
            guard let id = chat.card?.id else { return nil }
            return Binding(get: { chat.card?.images ?? [] }, set: { images in if chat.card?.id == id { chat.card?.images = images } })
        case .reply(let id):
            return model.replyImages(for: id)
        default:
            return nil
        }
    }

    private var inSidebar: Bool {
        switch focus {
        case .filter, .broadcast, .rename: true
        default: false
        }
    }

    /// Steps back one level: a proposal, the filter, a field, a session, the overlay. Never closes the window.
    private func escape() {
        switch focus {
        case .proposal:
            chat.cancelCard()
            setFocus(.composer)
        case .filter:
            model.query = ""
            model.overlayOpen = false
            setFocus(home)
        case .broadcast where model.broadcast?.confirming == true:
            model.broadcast?.confirming = false
        case .broadcast:
            model.broadcast = nil
            setFocus(home)
        case .rename:
            model.renaming = nil
            setFocus(home)
        case .reply:
            setFocus(nil)  // the draft stays for later
        case .composer:
            if chat.draft.isEmpty && chat.card != nil { chat.cancelCard() } else { model.overlayOpen = false }
        case nil:
            if model.overlayOpen {
                model.overlayOpen = false
            } else if model.pane != .chat {
                model.showChat()
            }
        }
    }
}
