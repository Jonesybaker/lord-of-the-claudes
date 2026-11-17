import LotcKit
import SwiftUI

/// One session in the main area: where it is, what it is doing, what it did, its prompts and a reply box.
struct SessionDetail: View {
    let row: Row
    @ObservedObject var model: WindowModel
    var focus: FocusState<MainField?>.Binding
    @State private var dropping = false

    private var place: String { SessionText.place(row, windowNames: model.windowNames) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    title
                    actions
                    if let digest = row.digest {
                        section("Summary") { DigestView(digest: digest) }
                    }
                    let earlier = Array(row.digestHistory.filter { $0 != row.digest }.reversed())
                    if !earlier.isEmpty {
                        section("Earlier") { DigestHistory(steps: earlier) }
                    }
                    section("Recent prompts") { prompts }
                }
                .readingColumn()
                .padding(.vertical, 16)
            }
            if row.isLive {
                VStack(alignment: .leading, spacing: 4) {
                    MessageBox(placeholder: "Send a prompt to this session", text: model.replyText(for: row.id),
                               images: model.replyImages(for: row.id), field: .reply(sessionId: row.id), focus: focus,
                               label: "Prompt for \(row.title)", send: { model.sendReply(to: row) })
                    if let note = model.replyNotes[row.id] { SendNoteView(note: note) }
                }
                .readingColumn()
                .padding(.top, 8).padding(.bottom, 12)
            }
        }
        .modifier(ReplyDrops(takes: row.isLive, images: model.replyImages(for: row.id), dropping: $dropping))
        .overlay { if dropping { DropHighlight() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if !model.sidebarVisible { SidebarButton(model: model) }
            Button(action: model.showChat) { Label("Overseer", systemImage: "chevron.left") }
                .help("Back to the chat (⌘L or Esc)")
            Spacer()
            Text("⌘R replies · Return goes to its tab").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: MainView.headerHeight)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SessionMarks(row: row)
                Text(row.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text(status).foregroundStyle(row.needsYou ? Color.waiting : .secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                fact("Where", row.isLive ? place : "Closed")
                fact("Topic", row.topicName + (row.topicPinned ? " (set by you)" : row.topic == nil ? " (its folder, until summarised)" : ""))
                fact("Directory", SessionText.shortPath(row.cwd))
            }
        }
    }

    private var status: String {
        guard row.isLive else { return "Closed. Last prompt \(shortAge(row.lastInteraction)) ago." }
        if row.needsYou, let since = row.statusSince { return "Waiting for you. Finished \(shortAge(since)) ago." }
        if row.status == "busy" { return "Working." }
        return "Idle. Last prompt \(shortAge(row.lastInteraction)) ago."
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(.callout).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if row.isLive {
                Button { model.goTo(row) } label: { Label("Go to tab", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .help("Brings its Ghostty tab to the front (Return)")
            } else {
                Button("Reopen") { model.goTo(row) }.buttonStyle(.borderedProminent).fixedSize()
            }
            if row.isLive && row.windowId != nil && !row.isLord {
                Button { model.store.makeLord(row.id) } label: { Label("Make lord", systemImage: "crown") }
                    .fixedSize()
                    .help("Make it the lord of its window: it can prompt the other sessions there with lotc")
            }
            Menu { TopicMenu(row: row, model: model) } label: { Label("Topic", systemImage: "folder") }
                .fixedSize()
                .help("Move it to another topic")
            if let ticket = row.ticket {
                Button { NSWorkspace.shared.open(ticket) } label: { Label("Ticket", systemImage: "ticket") }
                    .fixedSize()
                    .help(ticket.absoluteString)
            }
            Spacer(minLength: 0)
            closeButton
        }
        .fixedSize(horizontal: false, vertical: true)
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    @ViewBuilder private var closeButton: some View {
        if model.confirmingClose == row.id {
            Text(row.isLive ? "End it and close its tab?" : "Forget it?").font(.callout)
            Button("Cancel") { model.confirmingClose = nil }
            Button(row.isLive ? "Close" : "Forget", role: .destructive) { model.close(row) }
        } else {
            Button(row.isLive ? "Close..." : "Forget...") { model.confirmingClose = row.id }
                .fixedSize()
                .help(row.isLive ? "End the session and close its tab. It stays under Recently closed." : "Forget this session")
        }
    }

    private func section(_ name: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name.uppercased()).font(.caption2).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    @ViewBuilder private var prompts: some View {
        if row.prompts.isEmpty {
            Text("No prompts in Claude's history for this session.").foregroundStyle(.secondary)
        }
        ForEach(Array(row.prompts.enumerated().reversed()), id: \.offset) { _, prompt in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(shortAge(prompt.date))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
                Text(prompt.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A running session takes dropped images into its reply; a closed one has nowhere to send them.
private struct ReplyDrops: ViewModifier {
    let takes: Bool
    let images: Binding<[AttachedImage]>
    @Binding var dropping: Bool

    func body(content: Content) -> some View {
        if takes { content.takesDroppedImages(into: images, isTargeted: $dropping) } else { content }
    }
}

/// The observer's lines on a session.
struct DigestView: View {
    let digest: Digest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                line("Goal", digest.goal)
                line("Now", digest.state)
                if let blockedOn = digest.blockedOn { line("Blocked on", blockedOn, labelColour: .waiting) }
            }
            Text("Summarised \(shortAge(digest.at) == "now" ? "just now" : shortAge(digest.at) + " ago")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func line(_ label: String, _ text: String, labelColour: Color? = nil) -> some View {
        GridRow {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(labelColour.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .gridColumnAlignment(.trailing)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The steps a session went through before its latest digest, newest first.
struct DigestHistory: View {
    let steps: [Digest]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(shortAge(step.at))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    Text(step.state).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
