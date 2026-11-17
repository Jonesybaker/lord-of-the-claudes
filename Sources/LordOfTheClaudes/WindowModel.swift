import Combine
import SwiftUI

/// What the main area shows: the chat with the overseer, or one session.
enum MainPane: Equatable {
    case chat
    case session(String)
}

/// The main window's state and actions, apart from its views, so the keys, the menus and the menu bar
/// icon can all drive it. Focus stays in the view: this asks for it through `focusRequests`.
@MainActor
final class WindowModel: ObservableObject {
    let store: Store
    let chat: OverseerChat

    @Published var pane: MainPane = .chat
    /// The highlighted row: picked with the arrows or a click. Nil highlights nothing, except a filter's first match.
    @Published var selection: String?
    @Published var query = "" { didSet { if query != oldValue { selection = nil } } }
    @Published var grouping: Grouping { didSet { defaults?.set(grouping.rawValue, forKey: Keys.grouping) } }
    @Published var sidebarShown: Bool { didSet { defaults?.set(sidebarShown, forKey: Keys.sidebarShown) } }
    @Published var sidebarWidth: CGFloat
    /// Too narrow to dock the sidebar: it opens over the main area instead.
    @Published var compact = false
    @Published var overlayOpen = false
    /// Reply text not sent yet, by session id.
    @Published var drafts: [String: String] = [:]
    @Published var replyNotes: [String: SendNote] = [:]
    @Published var renaming: GroupRename?
    @Published var broadcast: BroadcastDraft?
    /// Broadcast results, by group id.
    @Published var groupNotes: [String: SendNote] = [:]
    @Published var showAllClosed = false
    @Published var confirmingStale = false
    /// The session whose Close is waiting for a second press.
    @Published var confirmingClose: String?
    /// The session waiting for the name of a new topic to move to.
    @Published var namingTopicFor: String?
    @Published var newTopicName = ""

    /// Where the keyboard should go next. Nil is the sidebar's list.
    let focusRequests = PassthroughSubject<MainField?, Never>()

    static let sidebarWidths: ClosedRange<CGFloat> = 240...480
    /// Narrower than this, the sidebar opens over the main area.
    static let compactWidth: CGFloat = 760
    private static let closedCap = 5

    private enum Keys {
        static let grouping = "grouping"
        static let sidebarShown = "sidebarShown"
        static let sidebarWidth = "sidebarWidth"
    }

    /// Nil `defaults` remembers nothing: the screenshots and tests.
    private let defaults: UserDefaults?

    init(store: Store, chat: OverseerChat, defaults: UserDefaults? = .standard) {
        self.store = store
        self.chat = chat
        self.defaults = defaults
        grouping = defaults?.string(forKey: Keys.grouping).flatMap(Grouping.init(rawValue:)) ?? .topic
        sidebarShown = defaults?.object(forKey: Keys.sidebarShown) as? Bool ?? true
        let width = defaults?.double(forKey: Keys.sidebarWidth) ?? 0
        sidebarWidth = width > 0 ? min(max(CGFloat(width), Self.sidebarWidths.lowerBound), Self.sidebarWidths.upperBound) : 320
    }

    // MARK: What the sidebar shows

    /// Running sessions grouped by topic or by window.
    var groups: [SidebarGroup] {
        let running = store.rows.filter(\.isLive)  // waiting first, then most recent prompt
        let query = query
        let match = { (row: Row, name: String) in SidebarGroups.matches(row, query: query, groupName: name) }
        switch grouping {
        case .window:
            let windows = store.groups.map { group in
                SidebarGroups.Window(id: group.id, name: group.name, rows: running.filter { $0.windowId == group.id },
                                     collapsed: group.collapsed)
            }
            return SidebarGroups.byWindow(windows, running: running, matches: match)
        case .topic:
            return SidebarGroups.byTopic(running: running, collapsed: store.collapsedTopics, matches: match)
        }
    }

    /// Closed sessions matching the filter: five unless asked for all, every one while filtering.
    var closed: (shown: [Row], total: Int) {
        let matching = store.rows.filter { !$0.isLive && SidebarGroups.matches($0, query: query) }
        let all = showAllClosed || !query.isEmpty
        return (all ? matching : Array(matching.prefix(Self.closedCap)), matching.count)
    }

    /// Every row on screen, in order.
    var visible: [Row] { groups.flatMap { $0.onScreen(filtering: !query.isEmpty) } + closed.shown }
    var stale: [Row] { store.rows.filter(\.isStale) }

    /// The row the keys act on: the highlighted one, or a filter's first match.
    var selectedRow: Row? {
        let visible = visible
        return visible.first { $0.id == selection } ?? (query.isEmpty ? nil : visible.first)
    }

    var shownSession: Row? {
        guard case .session(let id) = pane else { return nil }
        return store.rows.first { $0.id == id }
    }

    /// Each window's name, by window id, for rows grouped by topic to say where they are.
    var windowNames: [String: String] { Dictionary(store.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }

    var sidebarVisible: Bool { compact ? overlayOpen : sidebarShown }

    // MARK: Moving about

    func show(_ row: Row) {
        selection = row.id
        pane = .session(row.id)
        if compact { overlayOpen = false }
    }

    func showDetail() { if let row = selectedRow { show(row) } }

    func showChat() {
        pane = .chat
        if compact { overlayOpen = false }
        focusRequests.send(.composer)
    }

    func toggleSidebar() {
        if compact { overlayOpen.toggle() } else { sidebarShown.toggle() }
    }

    func revealSidebar() {
        if compact { overlayOpen = true } else { sidebarShown = true }
    }

    func setSidebarWidth(_ width: CGFloat, final: Bool) {
        sidebarWidth = min(max(width, Self.sidebarWidths.lowerBound), Self.sidebarWidths.upperBound)
        if final { defaults?.set(Double(sidebarWidth), forKey: Keys.sidebarWidth) }
    }

    /// The arrows. With nothing highlighted, the first row. A session on show follows the highlight.
    func moveSelection(_ delta: Int) {
        let visible = visible
        guard !visible.isEmpty else { return }
        let target: Row
        if let current = visible.firstIndex(where: { $0.id == selectedRow?.id }) {
            target = visible[min(max(current + delta, 0), visible.count - 1)]
        } else {
            target = visible[0]
        }
        select(target.id)
    }

    /// Cmd+Down and Cmd+Up: the first row of the next or previous group on screen. Recently closed comes last.
    func jumpSection(by delta: Int) {
        revealSidebar()
        let filtering = !query.isEmpty
        let closed = closed.shown
        let sections = groups.map { $0.onScreen(filtering: filtering).map(\.id) }.filter { !$0.isEmpty }
            + (closed.isEmpty ? [] : [closed.map(\.id)])
        if let target = SectionJump.target(from: selectedRow?.id, by: delta, in: sections) { select(target) }
    }

    /// Cmd+N: the first row of group N, unfolding it if need be.
    func jumpToGroup(_ number: Int) {
        guard let group = groups.first(where: { $0.number == number }), let first = group.shown.first else { return }
        revealSidebar()
        if group.collapsed == true, query.isEmpty { setCollapsed(group, false) }
        select(first.id)
    }

    private func select(_ id: String) {
        selection = id
        if case .session = pane { pane = .session(id) }
    }

    // MARK: Sessions

    /// Return on a row: its tab, or a closed session reopened.
    func goTo(_ row: Row) {
        if row.isLive { store.focus(row) } else { store.reopen(row) }
    }

    func close(_ row: Row) {
        confirmingClose = nil
        if row.isLive { store.close([row]) } else {
            store.forget(row)
            if pane == .session(row.id) { showChat() }
        }
    }

    /// Cmd+R: the selected session's detail with the keyboard in its reply field.
    func startReply() {
        guard let row = shownSession ?? selectedRow, row.isLive else { return }
        show(row)
        focusRequests.send(.reply(sessionId: row.id))
    }

    func replyText(for id: String) -> Binding<String> {
        Binding(get: { self.drafts[id, default: ""] },
                set: { text in
                    if text != self.drafts[id, default: ""] { self.replyNotes[id] = nil }
                    self.drafts[id] = text
                })
    }

    func sendReply(to row: Row) {
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

    func move(_ row: Row, toTopic topic: String) { store.move(row.id, toTopic: topic) }

    func saveNewTopic() {
        if let id = namingTopicFor, newTopicName.trimmedNonEmpty != nil { store.move(id, toTopic: newTopicName) }
        namingTopicFor = nil
        newTopicName = ""
    }

    /// Topics a session can be moved to: every group showing in topic grouping, then the rest in use.
    var topicChoices: [String] {
        let showing = Set(store.rows.filter(\.isLive).map { $0.topicName.lowercased() })
        let names = store.rows.filter(\.isLive).map(\.topicName) + store.topicsInUse.filter { !showing.contains($0.lowercased()) }
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Groups

    func setCollapsed(_ group: SidebarGroup, _ collapsed: Bool) {
        switch group.kind {
        case .window(let id): store.setCollapsed(id, collapsed)
        case .topic(let name): store.setTopicCollapsed(name, collapsed)
        case .other: break
        }
    }

    /// Folds a group or opens it. The highlight never stays on a row going out of sight.
    func toggleCollapsed(_ group: SidebarGroup) {
        guard let collapsed = group.collapsed else { return }
        if !collapsed && query.isEmpty, let selected = selectedRow?.id {
            let hiding = Set(group.shown.map(\.id))
            if hiding.contains(selected) {
                selection = SectionJump.survivor(of: selected, hiding: hiding, in: visible.map(\.id))
            }
        }
        setCollapsed(group, !collapsed)
    }

    func startRename(_ group: SidebarGroup) {
        guard group.kind != .other else { return }
        renaming = GroupRename(groupId: group.id, name: group.name)
        focusRequests.send(.rename(groupId: group.id))
    }

    /// A window's empty name goes back to its folder's; a topic's empty name hands its sessions back to the observer.
    func saveRename(_ group: SidebarGroup) {
        guard let renaming, renaming.groupId == group.id else { return }
        switch group.kind {
        case .window(let id): store.renameGroup(id, to: renaming.name)
        case .topic(let name): store.renameTopic(name, to: renaming.name)
        case .other: break
        }
        self.renaming = nil
        focusRequests.send(pane == .chat ? .composer : nil)
    }

    func toggleBroadcast(_ group: SidebarGroup) {
        groupNotes[group.id] = nil
        if broadcast?.groupId == group.id {
            broadcast = nil
            focusRequests.send(pane == .chat ? .composer : nil)
        } else {
            broadcast = BroadcastDraft(groupId: group.id)
            focusRequests.send(.broadcast(groupId: group.id))
        }
    }

    /// The first Return lists who it goes to, because a prompt to every session is expensive. The second
    /// sends to exactly those.
    func submitBroadcast(to group: SidebarGroup) {
        guard let draft = broadcast, draft.groupId == group.id, !draft.sending,
              let text = draft.text.trimmedNonEmpty
        else { return }
        guard draft.confirming else {
            broadcast?.confirming = true
            broadcast?.recipients = group.all.map(\.id)
            return
        }
        broadcast?.sending = true
        let recipients = draft.recipients
        Task {
            let sent = await store.broadcast(text, toSessions: recipients)
            let total = recipients.count
            groupNotes[group.id] = switch sent {
            case total: SendNote(outcome: .sent, text: "Sent to all \(total) sessions.")
            case 0: SendNote(outcome: .failed, text: "Could not find their tabs. Nothing was sent.")
            default: SendNote(outcome: .failed, text: "Sent to \(sent) of \(total) sessions. The rest had no tab to type into.")
            }
            announce(groupNotes[group.id])
            if broadcast?.groupId == group.id { broadcast = nil }
            focusRequests.send(pane == .chat ? .composer : nil)
        }
    }

    // MARK: The window

    /// Coming back from hidden starts at the chat with a clean slate, as the menu bar panel did.
    /// Brought forward while open, it keeps what it was showing.
    func windowShown(fromHidden: Bool) {
        if fromHidden {
            pane = .chat
            query = ""
            selection = nil
            overlayOpen = false
            confirmingStale = false
            confirmingClose = nil
            renaming = nil
            broadcast?.confirming = false
            replyNotes = [:]
            groupNotes = [:]
            chat.windowShown()
        }
        if pane == .chat { focusRequests.send(.composer) }
    }

    /// Reads a send's outcome out to VoiceOver, as it appears under a field the user may have left.
    private func announce(_ note: SendNote?) {
        if let note { AccessibilityNotification.Announcement(note.text).post() }
    }
}
