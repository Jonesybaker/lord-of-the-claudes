import SwiftUI

/// The heading over one group's sessions: a chevron to fold them away, its name, its counts,
/// a field to prompt them all and the Cmd+N that jumps to it.
struct GroupHeader: View {
    let group: SidebarGroup
    /// The sidebar has only this group: its name alone, small, as the sidebar's own header has the counts.
    let quiet: Bool
    @ObservedObject var model: WindowModel
    var focus: FocusState<MainField?>.Binding
    @State private var hoveringName = false

    private var renaming: Bool { model.renaming?.groupId == group.id }
    private var draft: BroadcastDraft? { model.broadcast.flatMap { $0.groupId == group.id ? $0 : nil } }
    private var canBroadcast: Bool { group.kind != .other && group.all.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let collapsed = group.collapsed {
                    chevron(collapsed)
                } else if !quiet {
                    Color.clear.frame(width: 12, height: 1)  // keeps "Other" in line with the rest
                }
                name.accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if !quiet { counts }
                if canBroadcast { broadcastButton }
                if !quiet && group.number <= 9 { shortcut }
            }
            if let draft {
                BroadcastField(draft: Binding(get: { model.broadcast ?? draft }, set: { model.broadcast = $0 }),
                               count: group.all.count, recipients: recipients(draft),
                               submit: { model.submitBroadcast(to: group) }, focus: focus)
            }
            if let note = model.groupNotes[group.id] { SendNoteView(note: note) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.top, quiet ? 6 : 12).padding(.bottom, 4)
    }

    /// Who the confirm says it goes to: each session's title and where it is.
    private func recipients(_ draft: BroadcastDraft) -> [String] {
        let names = model.windowNames
        return draft.recipients.compactMap { id in
            model.store.rows.first { $0.id == id }.map { "\($0.title) (\(SessionText.place($0, windowNames: names)))" }
        }
    }

    private var nameText: Text {
        quiet
            ? Text(group.name).font(.caption.weight(.medium))
            : Text(group.name).font(.subheadline.weight(.semibold))
    }

    @ViewBuilder private var name: some View {
        if renaming {
            TextField(group.topic == nil ? "Window name" : "Topic name",
                      text: Binding(get: { model.renaming?.name ?? "" }, set: { model.renaming?.name = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .frame(maxWidth: 220)
                .focused(focus, equals: .rename(groupId: group.id))
                .onSubmit { model.saveRename(group) }
                .help(group.topic == nil
                      ? "Return saves. Esc cancels. Empty goes back to the usual name."
                      : "Return renames it for every session in it. Another topic's name merges the two. Empty lets the observer choose again.")
        } else if group.kind != .other {
            Button { model.startRename(group) } label: {
                HStack(spacing: 4) {
                    nameText.lineLimit(1)
                    if hoveringName { Image(systemName: "pencil").font(.caption) }
                }
                .foregroundStyle(quiet ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .onHover { hoveringName = $0 }
            .help(group.topic == nil ? "Rename this window" : "Rename this topic")
            .accessibilityLabel("Rename \(group.name)")
        } else {
            nameText.lineLimit(1).foregroundStyle(quiet ? .secondary : .primary)
        }
    }

    private var counts: some View {
        HStack(spacing: 8) {
            if group.waitingCount > 0 {
                Text("\(group.waitingCount) waiting").foregroundStyle(Color.waiting)
            }
            Text("\(group.all.count) open").foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func chevron(_ collapsed: Bool) -> some View {
        Button { model.toggleCollapsed(group) } label: {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.caption.weight(.semibold))
                .frame(width: 12, height: 16)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.secondary)
        .help(collapsed ? "Show its sessions" : "Hide its sessions")
        .accessibilityLabel(collapsed ? "Show the sessions in \(group.name)" : "Hide the sessions in \(group.name)")
    }

    /// Quiet, so it does not compete with the counts.
    private var shortcut: some View {
        Text("⌘\(group.number)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .help("⌘\(group.number) jumps to this group")
            .accessibilityLabel("Command \(group.number) jumps to this group")
    }

    private var broadcastButton: some View {
        let label = "Send a prompt to all \(group.all.count) sessions in \(group.name)"
        return Button { model.toggleBroadcast(group) } label: {
            Image(systemName: draft == nil ? "megaphone" : "megaphone.fill")
        }
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Writes one prompt for every session in a group. The first Return lists who gets it; the second sends.
struct BroadcastField: View {
    @Binding var draft: BroadcastDraft
    let count: Int
    /// The sessions it will go to, named, once the confirm is showing.
    let recipients: [String]
    let submit: () -> Void
    var focus: FocusState<MainField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Send to all \(count) sessions", text: $draft.text)
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: .broadcast(groupId: draft.groupId))
                .onSubmit(submit)
                .disabled(draft.sending)
            if draft.sending {
                SendNoteView(note: SendNote(outcome: .sending, text: "Sending to \(draft.recipients.count) sessions..."))
            } else if draft.confirming {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send this to these \(recipients.count) sessions?").font(.callout.weight(.medium))
                    ForEach(recipients, id: \.self) { name in
                        Text("· " + name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { draft.confirming = false }.buttonStyle(.bordered)
                    Button("Send", action: submit).buttonStyle(.borderedProminent).help("Return sends it too")
                }
                .controlSize(.small)
            }
        }
    }
}
