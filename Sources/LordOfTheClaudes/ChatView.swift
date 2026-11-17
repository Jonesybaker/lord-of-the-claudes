import SwiftUI

/// The main area's chat with the overseer: newest at the bottom, a proposal waiting above the composer,
/// and "what needs me" when there is nothing else to show.
struct ChatView: View {
    @ObservedObject var chat: OverseerChat
    @ObservedObject var model: WindowModel
    var focus: FocusState<MainField?>.Binding

    private static let bottomId = "chat-bottom"
    private var store: Store { model.store }
    private var isEmpty: Bool { chat.conversation.messages.isEmpty && !chat.isAsking }
    private var showsNeeds: Bool { chat.showingNeeds || isEmpty }

    var body: some View {
        let places = store.overseerPlaces
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if showsNeeds {
                            ChatWelcome(model: model, chat: chat, asking: isEmpty)
                        } else {
                            ForEach(chat.conversation.messages) { message in bubble(message, places: places) }
                            if let streaming = chat.streaming { answering(streaming, places: places) }
                        }
                        Color.clear.frame(height: 1).id(Self.bottomId)
                    }
                    .readingColumn()
                    .padding(.vertical, 16)
                }
                .defaultScrollAnchor(showsNeeds ? .top : .bottom)
                .onChange(of: chat.conversation.messages.count) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                .onChange(of: chat.streaming) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                .onChange(of: showsNeeds) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            }
            VStack(spacing: 10) {
                if chat.card != nil { card }
                Composer(chat: chat, store: store, focus: focus)
            }
            .readingColumn()
            .padding(.top, 8).padding(.bottom, 12)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let id = AnswerText.sessionId(in: url) else { return .systemAction }
            if let row = store.rows.first(where: { $0.id == id }) { model.show(row) }
            return .handled
        })
        .onChange(of: chat.card?.id) { _, id in
            // Only when the user is not writing something else, so their typing never lands in a proposal.
            guard id != nil, chat.card?.hasPrompt == true, focus.wrappedValue == .composer, chat.draft.isEmpty else { return }
            DispatchQueue.main.async { focus.wrappedValue = .proposal }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if !model.sidebarVisible { SidebarButton(model: model) }
            Text("Overseer").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            Button { chat.showingNeeds.toggle() } label: {
                Label(chat.showingNeeds && !isEmpty ? "Back to the chat" : "What needs me",
                      systemImage: chat.showingNeeds && !isEmpty ? "bubble.left.and.bubble.right" : "bell")
            }
            .disabled(isEmpty)
            .help("Every session waiting for you, longest first")
            Button(action: chat.newChat) { Label("New chat", systemImage: "square.and.pencil") }
                .disabled(isEmpty)
                .help("Clear the conversation and start a new one with the overseer")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: MainView.headerHeight)
    }

    @ViewBuilder private func bubble(_ message: OverseerMessage, places: [SessionPlace]) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.18)))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(message.text)")
        case .overseer:
            Text(AnswerText.attributed(message.text, places: places))
                .textSelection(.enabled)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Overseer: \(message.text)")
        case .note:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                Text(message.text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func answering(_ text: String, places: [SessionPlace]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if text.isEmpty {
                ProgressView().controlSize(.small)
                Text("Thinking...").foregroundStyle(.secondary)
            } else {
                Text(AnswerText.attributed(text, places: places)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
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
                    focus.wrappedValue = .composer
                }
            },
            cancel: {
                chat.cancelCard()
                focus.wrappedValue = .composer
            },
            choose: { place in
                chat.choose(place)
                if chat.card?.hasPrompt == true { DispatchQueue.main.async { focus.wrappedValue = .proposal } }
            },
            focus: focus
        )
    }
}

/// The chat before anything is asked, and behind "What needs me": who is waiting, and things to ask.
struct ChatWelcome: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var chat: OverseerChat
    /// Nothing asked yet: offer some questions too.
    let asking: Bool

    static let examples = [
        "What needs me first?",
        "Where has each session got to?",
        "Which sessions look stuck?",
        "Take me to the one that has waited longest",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            NeedsYouList(rows: model.store.rows, places: model.store.overseerPlaces,
                         show: model.show, goTo: model.goTo)
            if asking {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TRY ASKING").font(.caption2).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    ForEach(Self.examples, id: \.self) { example in
                        Button {
                            chat.draft = example
                            chat.submit(to: model.store)
                        } label: {
                            Label(example, systemImage: "text.bubble")
                        }
                        .buttonStyle(.link)
                        .help("Ask the overseer this")
                    }
                }
            }
        }
    }
}

extension RoutingCard {
    /// It has a prompt to edit: a send, a new session or a "which one?" before a send.
    var hasPrompt: Bool {
        switch kind {
        case .send(let places, _): !places.isEmpty
        case .newSession, .choose: true
        case .goTo: false
        }
    }
}

/// About 80 characters of body text: answers wider than that are hard to read.
enum ReadingWidth {
    static let column: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let sample = "Two sessions are waiting for you: the checkout test and the passkeys work, longest first. "
        let perCharacter = (sample as NSString).size(withAttributes: [.font: font]).width / CGFloat(sample.count)
        return (perCharacter * 80).rounded()
    }()
}

extension View {
    /// Text held to a comfortable line length, left aligned, the column centred in the space.
    func readingColumn() -> some View {
        frame(maxWidth: ReadingWidth.column, alignment: .leading)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
    }
}
