import SwiftUI

/// A box for writing a message that grows to several lines, with any images pasted or dropped into it above
/// the words. Return sends and Shift+Return starts a new line; MainView's keys see to both, so the field never
/// takes Return itself.
struct MessageBox: View {
    let placeholder: String
    @Binding var text: String
    @Binding var images: [AttachedImage]
    let field: MainField
    var focus: FocusState<MainField?>.Binding
    /// The words read out for the field.
    let label: String
    let send: () -> Void
    /// While an answer is coming: a stop button in place of send.
    var stop: (() -> Void)? = nil

    private var focused: Bool { focus.wrappedValue == field }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 8) {
                if !images.isEmpty { AttachmentStrip(images: $images) }
                input
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focused ? Color.accentColor.opacity(0.8) : Color(nsColor: .separatorColor), lineWidth: focused ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture { focus.wrappedValue = field }
            Text("Return sends. Shift+Return starts a new line. Paste or drop an image to attach it.")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Its own placeholder: the field's draws as bright as typed text in the multi-line style.
            TextField("", text: $text.takingImagePaths(into: $images), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused(focus, equals: field)
                .accessibilityLabel(label)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(.secondary).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 2)
            if let stop {
                Button(action: stop) { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .help("Stop the answer")
                    .accessibilityLabel("Stop the answer")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(text.trimmedNonEmpty == nil && images.isEmpty)
                    .help("Send (Return)")
                    .accessibilityLabel("Send")
            }
        }
    }
}

/// The overseer's composer, pinned under the chat.
struct Composer: View {
    @ObservedObject var chat: OverseerChat
    let store: Store
    var focus: FocusState<MainField?>.Binding

    var body: some View {
        MessageBox(placeholder: "Ask the overseer, or tell a session what to do", text: $chat.draft,
                   images: $chat.draftImages, field: .composer,
                   focus: focus, label: "Message to the overseer", send: { chat.submit(to: store) },
                   stop: chat.isAsking ? { chat.stop() } : nil)
    }
}
