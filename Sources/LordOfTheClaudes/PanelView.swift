import Carbon.HIToolbox
import SwiftUI

private struct ContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Where the keyboard is in the panel. The arrows, Return and Tab move around the list only while
/// it is on the filter; in a reply, broadcast or rename field they edit the text.
enum PanelField: Hashable {
    case search
    case reply(sessionId: String)
    case broadcast(windowId: String)
    case rename(windowId: String)
}

/// The running sessions in one Ghostty window, or under "Other" when their tab cannot be found.
struct PanelGroup: Identifiable {
    /// Nil for "Other".
    let windowId: String?
    let name: String
    /// Its place in the panel, from 1: Cmd+1 to Cmd+9 jump to it.
    let number: Int
    /// Every running session in it, whatever the filter.
    let all: [Row]
    /// The ones matching the filter: waiting first, then most recent prompt.
    let shown: [Row]
    /// Folded away by the user. Nil when it cannot fold: "Other", or the only group.
    let collapsed: Bool?

    var id: String { windowId ?? "Other" }
    var waitingCount: Int { all.filter(\.needsYou).count }
    /// The rows under its header: none while folded, unless a filter is looking inside.
    func onScreen(filtering: Bool) -> [Row] { collapsed == true && !filtering ? [] : shown }
}

/// Where the selection lands when the panel jumps between groups or hides rows. Rows are ids in screen order.
enum SectionJump {
    /// The first row of the section `delta` sections on from the one holding `current`, stopping at the ends.
    static func target(from current: String?, by delta: Int, in sections: [[String]]) -> String? {
        guard !sections.isEmpty else { return nil }
        let here = sections.firstIndex { section in section.contains { $0 == current } } ?? 0
        return sections[min(max(here + delta, 0), sections.count - 1)].first
    }

    /// The row to select in place of `current` once `hiding` goes out of sight: the next one left, else the one before.
    static func survivor(of current: String, hiding: Set<String>, in order: [String]) -> String? {
        guard let at = order.firstIndex(of: current) else { return nil }
        return order[at...].first { !hiding.contains($0) } ?? order[..<at].last { !hiding.contains($0) }
    }
}

/// A prompt being written to every session in a group.
struct BroadcastDraft: Equatable {
    let windowId: String
    var text = "" { didSet { if text != oldValue { confirming = false } } }
    /// Return was pressed once and the count is on screen: the next Return sends.
    var confirming = false
    var sending = false
}

/// The group whose name is being edited, and the name typed so far.
struct GroupRename: Equatable {
    let windowId: String
    var name: String
}

struct PanelView: View {
    @ObservedObject var store: Store
    @State private var query = ""
    /// The highlighted row's id; nil means the first row.
    @State private var selection: String?
    @State private var expanded: Set<String>
    @State private var confirmingStale = false
    @State private var listHeight: CGFloat = 0
    @FocusState private var focus: PanelField?
    @State private var keys = PanelKeys()
    /// Reply text not sent yet, by session id.
    @State private var drafts: [String: String]
    @State private var replyNotes: [String: SendNote] = [:]
    @State private var renaming: GroupRename?
    @State private var broadcast: BroadcastDraft?
    /// Broadcast results, by window id.
    @State private var groupNotes: [String: SendNote] = [:]

    /// The screenshots start it with rows expanded, a reply typed or a broadcast awaiting its confirm.
    init(store: Store, expanded: Set<String> = [], drafts: [String: String] = [:], broadcast: BroadcastDraft? = nil) {
        self.store = store
        _expanded = State(initialValue: expanded)
        _drafts = State(initialValue: drafts)
        _broadcast = State(initialValue: broadcast)
    }

    private func matches(_ row: Row, groupName: String = "") -> Bool {
        query.isEmpty || [row.title, row.cwd, groupName].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Running sessions by Ghostty window in window order, then "Other".
    private var groups: [PanelGroup] {
        let running = store.rows.filter(\.isLive)  // already waiting first, then most recent prompt
        let windows = store.groups
        var found = windows.map { group in
            (windowId: Optional(group.id), name: group.name, all: running.filter { $0.windowId == group.id },
             collapsed: group.collapsed)
        }
        let grouped = Set(windows.map(\.id))
        let other = running.filter { row in row.windowId.map { !grouped.contains($0) } ?? true }
        if !other.isEmpty { found.append((windowId: nil, name: "Other", all: other, collapsed: false)) }
        // A lone group has nothing to make room for.
        let canFold = found.count > 1
        return found.enumerated().map { index, group in
            PanelGroup(windowId: group.windowId, name: group.name, number: index + 1, all: group.all,
                       shown: group.all.filter { matches($0, groupName: group.windowId == nil ? "" : group.name) },
                       collapsed: canFold && group.windowId != nil ? group.collapsed : nil)
        }
    }

    private var closed: [Row] { Array(store.rows.filter { !$0.isLive && matches($0) }.prefix(15)) }

    /// Every row on screen, in display order.
    private var visible: [Row] { groups.flatMap { $0.onScreen(filtering: !query.isEmpty) } + closed }
    private var stale: [Row] { store.rows.filter(\.isStale) }

    private var selectedRow: Row? {
        let visible = visible
        return visible.first { $0.id == selection } ?? visible.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.automationBlocked { notice("Cannot talk to Ghostty. Allow Lord of the Claudes under System Settings > Privacy & Security > Automation.") }
            if !store.pending.isEmpty { pendingBanner }
            search
            Divider()
            list
            if !stale.isEmpty { staleBanner }
            Divider()
            footer
        }
        .frame(width: 460)
        .onAppear {
            keys.handler = handleKey
            focusSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow)?.className.contains("MenuBarExtraWindow") == true { resetForOpen() }
        }
        .onChange(of: query) { selection = nil }
        .onChange(of: focus) { old, _ in
            // Clicking away from a group's name field cancels the rename, as Esc does.
            if case .rename(let windowId) = old, renaming?.windowId == windowId { renaming = nil }
        }
    }

    private func resetForOpen() {
        query = ""
        selection = nil
        confirmingStale = false
        renaming = nil
        broadcast?.confirming = false
        replyNotes = [:]
        groupNotes = [:]
        focusSearch()
    }

    private func focusSearch() {
        // Focus only sticks once the window is key, which is a beat after it appears.
        DispatchQueue.main.async { focus = .search }
    }

    // MARK: Keys

    /// Every key press in the panel comes here first. Returns true if it was used.
    private func handleKey(_ event: NSEvent) -> Bool {
        let keyCode = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if keyCode == kVK_Escape && modifiers.isEmpty {
            escape()
            return true
        }
        // A reply, broadcast or rename field takes every other key, arrows and Return included.
        if let focus, focus != .search { return false }

        if modifiers == .command && event.charactersIgnoringModifiers == "r" {
            if let row = selectedRow, row.isLive { startReply(to: row) }
            return true
        }
        if modifiers == .command {
            switch keyCode {
            case kVK_DownArrow: jumpSection(by: 1)
            case kVK_UpArrow: jumpSection(by: -1)
            default:
                guard let number = Self.numberKeys[keyCode] else { return false }
                jumpToGroup(number)
            }
            return true
        }
        guard modifiers.isEmpty else { return false }
        let selected = selectedRow
        switch keyCode {
        case kVK_DownArrow: moveSelection(1)
        case kVK_UpArrow: moveSelection(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter: if let selected { activate(selected) }
        case kVK_Tab: if let selected { toggleExpanded(selected) }
        case kVK_RightArrow: if let selected { expanded.insert(selected.id) }
        case kVK_LeftArrow: if let selected { expanded.remove(selected.id) }
        default: return false
        }
        return true
    }

    /// Steps back one level: out of a broadcast's confirm, then out of the field, then closes the panel.
    private func escape() {
        switch focus {
        case .broadcast where broadcast?.confirming == true:
            broadcast?.confirming = false
        case .broadcast:
            broadcast = nil
            focus = .search
        case .rename:
            renaming = nil
            focus = .search
        case .reply:
            focus = .search  // the draft stays for later
        case .search, nil:
            Panel.close()
        }
    }

    private func moveSelection(_ delta: Int) {
        let visible = visible
        guard let current = visible.firstIndex(where: { $0.id == selectedRow?.id }) else { return }
        selection = visible[min(max(current + delta, 0), visible.count - 1)].id
    }

    /// Cmd+1 to Cmd+9 by key position, whatever the keyboard layout.
    private static let numberKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    /// Cmd+Down and Cmd+Up: the first row of the next or previous group on screen. Recently closed comes last.
    private func jumpSection(by delta: Int) {
        let filtering = !query.isEmpty
        let closed = self.closed
        let sections = groups.map { $0.onScreen(filtering: filtering).map(\.id) }.filter { !$0.isEmpty }
            + (closed.isEmpty ? [] : [closed.map(\.id)])
        if let target = SectionJump.target(from: selectedRow?.id, by: delta, in: sections) { selection = target }
    }

    /// Cmd+N: the first row of group N, unfolding it if need be.
    private func jumpToGroup(_ number: Int) {
        guard let group = groups.first(where: { $0.number == number }), let first = group.shown.first else { return }
        if group.collapsed == true, query.isEmpty, let windowId = group.windowId { store.setCollapsed(windowId, false) }
        selection = first.id
    }

    // MARK: Actions

    private func activate(_ row: Row) {
        if row.isLive {
            store.focus(row)
            Panel.close()
        } else {
            store.reopen(row)
        }
    }

    private func toggleCollapsed(_ group: PanelGroup) {
        guard let windowId = group.windowId, let collapsed = group.collapsed else { return }
        if !collapsed && query.isEmpty {
            // Neither the selection nor the keyboard may stay on a row going out of sight.
            let hiding = Set(group.shown.map(\.id))
            if case .reply(let id) = focus, hiding.contains(id) { focus = .search }
            if let selected = selectedRow?.id, hiding.contains(selected) {
                selection = SectionJump.survivor(of: selected, hiding: hiding, in: visible.map(\.id))
            }
        }
        store.setCollapsed(windowId, !collapsed)
    }

    private func toggleExpanded(_ row: Row) {
        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
    }

    /// Opens the session's prompts with the cursor in its reply field.
    private func startReply(to row: Row) {
        expanded.insert(row.id)
        selection = row.id
        // The field only exists once the row has expanded.
        DispatchQueue.main.async { focus = .reply(sessionId: row.id) }
    }

    private func sendReply(to row: Row) {
        let text = drafts[row.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        drafts[row.id] = ""
        replyNotes[row.id] = SendNote(outcome: .sending, text: "Sending...")
        Task {
            let sent = await store.send(text, toSession: row.id)
            if !sent && drafts[row.id, default: ""].isEmpty { drafts[row.id] = text }  // give the words back
            replyNotes[row.id] = sent ? SendNote(outcome: .sent, text: "Sent.")
                                      : SendNote(outcome: .failed, text: "Could not find its tab. Nothing was sent.")
            announce(replyNotes[row.id])
        }
    }

    private func startRename(_ windowId: String, from name: String) {
        renaming = GroupRename(windowId: windowId, name: name)
        DispatchQueue.main.async { focus = .rename(windowId: windowId) }
    }

    private func saveRename() {
        guard let renaming else { return }
        store.renameGroup(renaming.windowId, to: renaming.name)  // empty goes back to the usual name
        self.renaming = nil
        focus = .search
    }

    private func toggleBroadcast(_ windowId: String) {
        groupNotes[windowId] = nil
        if broadcast?.windowId == windowId {
            broadcast = nil
            focus = .search
        } else {
            broadcast = BroadcastDraft(windowId: windowId)
            DispatchQueue.main.async { focus = .broadcast(windowId: windowId) }
        }
    }

    /// The first Return asks, naming the count, because a prompt to every session is expensive. The second sends.
    private func submitBroadcast(to group: PanelGroup) {
        guard let draft = broadcast, draft.windowId == group.windowId, !draft.sending else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard draft.confirming else {
            broadcast?.confirming = true
            return
        }
        broadcast?.sending = true
        let count = group.all.count
        Task {
            let sent = await store.broadcast(text, toGroup: draft.windowId)
            let total = max(count, sent)
            groupNotes[draft.windowId] = switch sent {
            case total: SendNote(outcome: .sent, text: "Sent to all \(total) sessions.")
            case 0: SendNote(outcome: .failed, text: "Could not find their tabs. Nothing was sent.")
            default: SendNote(outcome: .failed, text: "Sent to \(sent) of \(total) sessions. The rest had no tab to type into.")
            }
            announce(groupNotes[draft.windowId])
            if broadcast?.windowId == draft.windowId { broadcast = nil }
            if focus == .broadcast(windowId: draft.windowId) { focus = .search }
        }
    }

    /// Reads a send's outcome out to VoiceOver, as it appears under a field the user may have left.
    private func announce(_ note: SendNote?) {
        if let note { AccessibilityNotification.Announcement(note.text).post() }
    }

    // MARK: Views

    private var header: some View {
        HStack {
            Text("Claude sessions").font(.headline)
            Text(HotKey.display).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            if store.needsYouCount > 0 {
                Text("\(store.needsYouCount) waiting for you").font(.subheadline).foregroundStyle(Color.waiting)
            }
            Text(store.ghosttyRunning ? "\(store.liveCount) open" : "Ghostty is not running")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }

    private var search: some View {
        TextField("Filter. Return jumps to the session, Right shows its prompts", text: $query)
            .textFieldStyle(.roundedBorder)
            .focused($focus, equals: .search)
            .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func sessionRow(_ row: Row, selected: Bool) -> some View {
        SessionRow(
            row: row, selected: selected, expanded: expanded.contains(row.id),
            activate: { activate(row) },
            toggleExpanded: { toggleExpanded(row) },
            remove: { if row.isLive { store.close([row]) } else { store.forget(row) } },
            makeLord: row.isLive && row.windowId != nil && !row.isLord ? { store.makeLord(row.id) } : nil,
            replyText: Binding(
                get: { drafts[row.id, default: ""] },
                set: { text in
                    if text != drafts[row.id, default: ""] { replyNotes[row.id] = nil }
                    drafts[row.id] = text
                }
            ),
            replyNote: replyNotes[row.id],
            sendReply: { sendReply(to: row) },
            focus: $focus
        )
    }

    private func groupHeader(_ group: PanelGroup, quiet: Bool) -> some View {
        let windowId = group.windowId
        let isRenaming = windowId != nil && renaming?.windowId == windowId
        let draft = broadcast.flatMap { $0.windowId == windowId ? $0 : nil }
        return GroupHeader(
            group: group, quiet: quiet,
            toggleCollapsed: { toggleCollapsed(group) },
            renameText: isRenaming ? Binding(get: { renaming?.name ?? "" }, set: { renaming?.name = $0 }) : nil,
            startRename: windowId.map { id in { startRename(id, from: group.name) } },
            saveRename: saveRename,
            broadcast: draft.map { draft in Binding(get: { broadcast ?? draft }, set: { broadcast = $0 }) },
            toggleBroadcast: windowId.flatMap { id in group.all.count > 1 ? { toggleBroadcast(id) } : nil },
            submitBroadcast: { submitBroadcast(to: group) },
            note: windowId.flatMap { groupNotes[$0] },
            focus: $focus
        )
    }

    private static let closedHeaderId = "header-closed"
    private static func headerId(_ group: PanelGroup) -> String { "header-" + group.id }

    /// The heading over `rowId` when it is the first row of its section, so a jump there shows the heading too.
    private func headerId(over rowId: String) -> String? {
        let filtering = !query.isEmpty
        if let group = groups.first(where: { $0.onScreen(filtering: filtering).first?.id == rowId }) {
            return Self.headerId(group)
        }
        return closed.first?.id == rowId ? Self.closedHeaderId : nil
    }

    private var list: some View {
        let groups = groups
        let closed = closed
        let filtering = !query.isEmpty
        let selectedId = selectedRow?.id
        // "Other" on its own is the plain list of old, so needs no heading; one window gets a quiet one.
        let headed = !(groups.count == 1 && groups[0].windowId == nil)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups.filter { !$0.shown.isEmpty }) { group in
                        if headed { groupHeader(group, quiet: groups.count == 1).id(Self.headerId(group)) }
                        ForEach(group.onScreen(filtering: filtering)) { row in sessionRow(row, selected: row.id == selectedId) }
                    }
                    if !closed.isEmpty {
                        Text("RECENTLY CLOSED")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                            .id(Self.closedHeaderId)
                        ForEach(closed) { row in sessionRow(row, selected: row.id == selectedId) }
                    }
                    if groups.allSatisfy(\.shown.isEmpty) && closed.isEmpty {
                        Text(query.isEmpty ? "No Claude sessions seen yet." : "No sessions match.")
                            .foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(.vertical, 4)
                .background(GeometryReader { Color.clear.preference(key: ContentHeight.self, value: $0.size.height) })
            }
            // A ScrollView has no intrinsic height and collapses to nothing in a menu bar window,
            // so size it to its content up to a cap.
            .frame(height: min(540, max(listHeight, 30)))
            .onPreferenceChange(ContentHeight.self) { listHeight = $0 }
            .onChange(of: selection) {
                guard let selection else { return }
                if let header = headerId(over: selection) { proxy.scrollTo(header, anchor: .top) } else { proxy.scrollTo(selection) }
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
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.15))
    }

    private var staleBanner: some View {
        HStack {
            Text("\(stale.count) open sessions untouched for over a week.")
            Spacer()
            if confirmingStale {
                Button("Close \(stale.count) sessions") { store.close(stale); confirmingStale = false }
                Button("Cancel") { confirmingStale = false }
            } else {
                Button("Close them...") { confirmingStale = true }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.05))
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.2))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Toggle("Reopen when Ghostty starts", isOn: $store.autoRestore)
            Toggle("Launch at login", isOn: $store.launchAtLogin)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
