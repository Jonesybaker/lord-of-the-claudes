import Carbon.HIToolbox
import SwiftUI

/// Who gets a key press made in the overseer's field or on a routing card. PanelView asks this first.
enum OverseerKeys {
    enum Route: Equatable {
        /// The text field types it.
        case field
        /// The session list handles it, as it did from the filter.
        case list
        case focusFilter
        case confirmCard
    }

    /// In the chat field the arrows and Cmd shortcuts work the list, as the filter's did. Return asks
    /// the overseer, or with nothing typed jumps to the selected session; Tab, Right and Left work the
    /// list only while nothing is typed. On a card's prompt Return is Send.
    static func route(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?,
                      focus: PanelField?, chatIsEmpty: Bool) -> Route {
        let modifiers = modifiers.intersection([.command, .control, .option, .shift])
        let isReturn = keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter
        switch focus {
        case .proposal:
            return isReturn && modifiers.isEmpty ? .confirmCard : .field
        case .overseer:
            if modifiers == .command {
                return characters == "f" ? .focusFilter : .list
            }
            guard modifiers.isEmpty else { return .field }
            switch keyCode {
            case kVK_UpArrow, kVK_DownArrow: return .list
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_RightArrow, kVK_LeftArrow: return chatIsEmpty ? .list : .field
            default: return .field
            }
        case .search, nil:
            return modifiers == .command && characters == "f" ? .focusFilter : .list
        default:
            return .field
        }
    }
}

/// The top of the panel: the chat with the overseer, its proposals, and "What needs me".
struct OverseerView: View {
    @ObservedObject var chat: OverseerChat
    @ObservedObject var store: Store
    var focus: FocusState<PanelField?>.Binding
    /// Jumps to a session's tab and closes the panel.
    let jump: (Row) -> Void
    @State private var height: CGFloat = 0

    private static let bottomId = "overseer-bottom"

    var body: some View {
        let places = store.overseerPlaces
        VStack(alignment: .leading, spacing: 6) {
            toolbar
            scrolling(places)
            if chat.card != nil { card }
            field
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .environment(\.openURL, OpenURLAction { url in
            guard let id = AnswerText.sessionId(in: url) else { return .systemAction }
            if let row = store.rows.first(where: { $0.id == id }) { jump(row) }
            return .handled
        })
        .onChange(of: chat.card?.id) { _, id in
            // Only when the user is not writing something else, so their typing never lands in a proposal.
            if id != nil, focus.wrappedValue == .overseer, chat.draft.isEmpty {
                DispatchQueue.main.async { focus.wrappedValue = .proposal }
            }
        }
    }

    private var showsNeeds: Bool { chat.showingNeeds || (chat.conversation.messages.isEmpty && !chat.isAsking) }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Overseer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { chat.showingNeeds.toggle() } label: {
                Label(chat.showingNeeds && !chat.conversation.messages.isEmpty ? "Back to the chat" : "What needs me",
                      systemImage: chat.showingNeeds ? "bubble.left.and.bubble.right" : "bell")
            }
            .disabled(chat.conversation.messages.isEmpty && !chat.isAsking)
            .help("Every session waiting for you, longest first")
            Button(action: chat.newChat) { Label("New chat", systemImage: "square.and.pencil") }
                .disabled(chat.conversation.messages.isEmpty && !chat.isAsking)
                .help("Clear the conversation and start a new one with the overseer")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.top, 2)
    }

    /// The conversation, or the waiting list, sized to its content up to a cap (see PanelView's list).
    private func scrolling(_ places: [SessionPlace]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if showsNeeds {
                        NeedsYouList(rows: store.rows, places: places, jump: jump)
                    } else {
                        ForEach(chat.conversation.messages) { message in bubble(message, places: places) }
                        if let streaming = chat.streaming { answering(streaming, places: places) }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomId)
                }
                .padding(.vertical, 2)
                .background(GeometryReader { Color.clear.preference(key: OverseerHeight.self, value: $0.size.height) })
            }
            .frame(height: min(PanelHeights.conversation, max(height, 20)))
            .onPreferenceChange(OverseerHeight.self) { height = $0 }
            .onChange(of: chat.conversation.messages.count) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            .onChange(of: chat.streaming) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            .onChange(of: showsNeeds) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            .onAppear { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
        }
    }

    @ViewBuilder private func bubble(_ message: OverseerMessage, places: [SessionPlace]) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.18)))
            }
            .accessibilityLabel("You: \(message.text)")
        case .overseer:
            Text(AnswerText.attributed(message.text, places: places))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .note:
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "info.circle")
                Text(message.text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func answering(_ text: String, places: [SessionPlace]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if text.isEmpty {
                ProgressView().controlSize(.small)
                Text("Thinking...").foregroundStyle(.secondary)
            } else {
                Text(AnswerText.attributed(text, places: places)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var card: some View {
        RoutingCardView(
            card: Binding(get: { chat.card ?? RoutingCard(kind: .send([], missing: []), prompt: "") },
                          set: { chat.card = $0 }),
            send: {
                Task {
                    await chat.confirm(using: store)
                    focus.wrappedValue = .overseer
                }
            },
            cancel: {
                chat.cancelCard()
                focus.wrappedValue = .overseer
            },
            choose: { place in
                chat.choose(place)
                DispatchQueue.main.async { focus.wrappedValue = .proposal }
            },
            focus: focus
        )
    }

    private var field: some View {
        HStack(spacing: 6) {
            TextField("Ask the overseer, or tell a session what to do", text: $chat.draft)
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: .overseer)
                .onSubmit { chat.submit(to: store) }
                .help("Return asks. With nothing typed, Return jumps to the selected session and the arrows move through the list. ⌘F filters.")
            if chat.isAsking {
                Button(action: chat.stop) { Image(systemName: "stop.circle") }
                    .buttonStyle(.borderless)
                    .help("Stop the answer")
                    .accessibilityLabel("Stop the answer")
            }
        }
    }
}

/// Caps that keep the panel on a laptop screen with the chat, a card and the list all showing.
@MainActor
enum PanelHeights {
    /// Set by the screenshots, so they do not depend on the screen they were taken on.
    static var screenOverride: CGFloat?
    private static var screen: CGFloat { screenOverride ?? NSScreen.main?.visibleFrame.height ?? 900 }
    static var conversation: CGFloat { min(240, screen * 0.22) }
    static var list: CGFloat { min(540, screen * 0.4) }
}

private struct OverseerHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
