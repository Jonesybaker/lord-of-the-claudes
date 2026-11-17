import SwiftUI

/// The left column: the filter, the overseer, the sessions by topic or window, recently closed and the settings.
struct Sidebar: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var store: Store
    @ObservedObject var chat: OverseerChat
    var focus: FocusState<MainField?>.Binding

    private static let closedHeaderId = "header-closed"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                TextField("Filter (⌘F)", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused(focus, equals: .filter)
                    .help("Return goes to the first match. Down and Up move, Right shows its detail.")
                Picker("Group by", selection: $model.grouping) {
                    Text("By topic").tag(Grouping.topic)
                    Text("By window").tag(Grouping.window)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Group sessions by what they are about, or by Ghostty window")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            overseerRow
            AutoApproveSidebarRow(model: model, approvals: store.approvals)
            Divider()
            list
            if !model.stale.isEmpty { staleBanner }
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            SidebarButton(model: model)
            Text("Sessions").font(.headline)
            Spacer()
            if store.needsYouCount > 0 {
                Text("\(store.needsYouCount) waiting").font(.callout).foregroundStyle(Color.waiting)
            }
            Text(store.ghosttyRunning ? "\(store.liveCount) open" : "Ghostty is not running")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: MainView.headerHeight)
    }

    /// The way back to the chat, with what it is doing.
    private var overseerRow: some View {
        let showing = model.pane == .chat
        return Button { model.showChat() } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Overseer")
                    Text(overseerStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("⌘L").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(showing ? Color.accentColor.opacity(0.25) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Chat with the overseer (⌘L)")
        .accessibilityLabel("Overseer. \(overseerStatus)")
        .accessibilityAddTraits(showing ? .isSelected : [])
    }

    private var overseerStatus: String {
        if chat.isAsking { return "Answering..." }
        if let card = chat.card { return card.isGoTo ? "Waiting for your Go" : "Waiting for your Send" }
        if let last = chat.conversation.messages.last(where: { $0.role != .note }) {
            return SessionText.oneLine(last.role == .user ? "You: " + last.text : AnswerText.plain(last.text))
        }
        return "Ask what needs you"
    }

    private var list: some View {
        let groups = model.groups
        let closed = model.closed
        let filtering = !model.query.isEmpty
        let highlighted = model.selectedRow?.id
        let showing = model.shownSession?.id
        let names = model.grouping == .topic ? model.windowNames : nil
        // "Other" on its own is the plain list of old, so needs no heading; one group gets a quiet one.
        let headed = !(groups.count == 1 && groups[0].kind == .other)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups.filter { !$0.shown.isEmpty }) { group in
                        if headed { GroupHeader(group: group, quiet: groups.count == 1, model: model, focus: focus).id("header-" + group.id) }
                        ForEach(group.onScreen(filtering: filtering)) { row in
                            SessionRow(row: row, showing: row.id == showing, highlighted: row.id == highlighted,
                                       place: names.map { SessionText.place(row, windowNames: $0) }, model: model)
                        }
                    }
                    if !closed.shown.isEmpty {
                        Text("RECENTLY CLOSED")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                            .id(Self.closedHeaderId)
                        ForEach(closed.shown) { row in
                            SessionRow(row: row, showing: row.id == showing, highlighted: row.id == highlighted, place: nil, model: model)
                        }
                        if closed.shown.count < closed.total {
                            Button("Show all \(closed.total)") { model.showAllClosed = true }
                                .buttonStyle(.link)
                                .font(.callout)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                    if groups.allSatisfy(\.shown.isEmpty) && closed.shown.isEmpty {
                        Text(model.query.isEmpty ? "No Claude sessions seen yet." : "No sessions match.")
                            .foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.selection) { _, selection in
                guard let selection else { return }
                // The first row of a section brings its heading into view with it.
                if let group = groups.first(where: { $0.onScreen(filtering: filtering).first?.id == selection }) {
                    proxy.scrollTo("header-" + group.id, anchor: .top)
                } else if closed.shown.first?.id == selection {
                    proxy.scrollTo(Self.closedHeaderId, anchor: .top)
                } else {
                    proxy.scrollTo(selection)
                }
            }
        }
    }

    private var staleBanner: some View {
        let stale = model.stale
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(stale.count) open sessions untouched for over a week.")
            HStack {
                Spacer()
                if model.confirmingStale {
                    Button("Cancel") { model.confirmingStale = false }
                    Button("Close \(stale.count) sessions") { store.close(stale); model.confirmingStale = false }
                } else {
                    Button("Close them...") { model.confirmingStale = true }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.05))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Toggle("Reopen with Ghostty", isOn: $store.autoRestore).fixedSize()
                    .help("When Ghostty starts, reopen the sessions that were open when it last closed.")
                Toggle("Summaries", isOn: $store.summarise).fixedSize()
                    .help("Each time Claude stops, Haiku sums the session up and files it under a topic. Needs lotc hooks install.")
            }
            HStack {
                Toggle("Launch at login", isOn: $store.launchAtLogin).fixedSize()
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Shows or hides the sidebar, docked or over the main area: ⌘0.
struct SidebarButton: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        Button(action: model.toggleSidebar) {
            Image(systemName: "sidebar.left").frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(model.sidebarVisible ? "Hide the sidebar (⌘0)" : "Show the sidebar (⌘0)")
        .accessibilityLabel(model.sidebarVisible ? "Hide the sidebar" : "Show the sidebar")
    }
}
