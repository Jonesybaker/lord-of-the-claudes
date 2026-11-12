import SwiftUI

/// The heading over one group's sessions: its name, its counts and a field to prompt them all.
struct GroupHeader: View {
    let group: PanelGroup
    /// The panel has only this group: its name alone, small, as the panel's own header has the counts.
    let quiet: Bool
    /// The name typed so far, while the group is being renamed.
    let renameText: Binding<String>?
    /// Nil when it cannot be renamed ("Other" is not a window).
    let startRename: (() -> Void)?
    let saveRename: () -> Void
    /// The prompt for every session, while that field is open.
    let broadcast: Binding<BroadcastDraft>?
    /// Nil when there is nobody to broadcast to: "Other", or a single session.
    let toggleBroadcast: (() -> Void)?
    let submitBroadcast: () -> Void
    let note: SendNote?
    var focus: FocusState<PanelField?>.Binding
    @State private var hoveringName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                name.accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if !quiet { counts }
                if let toggleBroadcast { broadcastButton(toggleBroadcast) }
            }
            if let broadcast {
                BroadcastField(draft: broadcast, count: group.all.count, submit: submitBroadcast, focus: focus)
            }
            if let note { SendNoteView(note: note) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.top, quiet ? 6 : 12).padding(.bottom, 4)
    }

    private var nameText: Text {
        quiet
            ? Text(group.name).font(.caption.weight(.medium))
            : Text(group.name).font(.subheadline.weight(.semibold))
    }

    @ViewBuilder private var name: some View {
        if let renameText, let windowId = group.windowId {
            TextField("Group name", text: renameText)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .frame(maxWidth: 220)
                .focused(focus, equals: .rename(windowId: windowId))
                .onSubmit(saveRename)
                .help("Return saves. Esc cancels. Empty goes back to the usual name.")
        } else if let startRename {
            Button(action: startRename) {
                HStack(spacing: 4) {
                    nameText.lineLimit(1)
                    if hoveringName { Image(systemName: "pencil").font(.caption) }
                }
                .foregroundStyle(quiet ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .onHover { hoveringName = $0 }
            .help("Rename this group")
            .accessibilityLabel("Rename group \(group.name)")
        } else {
            nameText.lineLimit(1).foregroundStyle(quiet ? .secondary : .primary)
        }
    }

    private var counts: some View {
        HStack(spacing: 8) {
            if group.waitingCount > 0 {
                Text("\(group.waitingCount) waiting for you").foregroundStyle(Color.waiting)
            }
            Text("\(group.all.count) open").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func broadcastButton(_ action: @escaping () -> Void) -> some View {
        let label = "Send a prompt to all \(group.all.count) sessions in this group"
        return Button(action: action) {
            Image(systemName: broadcast == nil ? "megaphone" : "megaphone.fill")
        }
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Writes one prompt for every session in a group. The first Return asks, naming the count; the second sends.
struct BroadcastField: View {
    @Binding var draft: BroadcastDraft
    let count: Int
    let submit: () -> Void
    var focus: FocusState<PanelField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Send to all \(count) sessions", text: $draft.text)
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: .broadcast(windowId: draft.windowId))
                .onSubmit(submit)
                .disabled(draft.sending)
            if draft.sending {
                SendNoteView(note: SendNote(outcome: .sending, text: "Sending to \(count) sessions..."))
            } else if draft.confirming {
                HStack(spacing: 8) {
                    Text("Send this to all \(count) sessions?").font(.callout.weight(.medium))
                    Spacer()
                    Button("Send", action: submit).buttonStyle(.bordered).help("Return sends it too")
                    Button("Cancel") { draft.confirming = false }.buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
    }
}
