import AppKit
import Foundation
import ServiceManagement

/// A session we have seen running. Kept after it closes so it can be reopened.
struct Record: Codable {
    var id: String
    var cwd: String
    var title: String
    var lastSeen: Date
    var lastInteraction: Date
    /// Index of its tab among Ghostty's terminals in window/tab order, so it can go back where it was.
    var position: Int?
    /// Last time its tab was the one in front of the user.
    var seenAt: Date?
    /// Closed from the panel, so not to be reopened automatically.
    var closedByUser: Bool?
    /// The name the user gave the group (Ghostty window) this session is in.
    var group: String?
    /// This session directs the others in its window.
    var isLord: Bool?
}

struct SavedState: Codable {
    /// Last time we polled while Ghostty was up. Sessions seen within `grace` of this were open when Ghostty went away.
    var heartbeat = Date.distantPast
    var records: [Record] = []
}

struct Row: Identifiable {
    static let staleAfter: TimeInterval = 7 * 24 * 3600

    let id: String
    let title: String
    let cwd: String
    let status: String?  // nil when the session is not running
    let statusSince: Date?
    let lastInteraction: Date
    /// Claude has stopped and the user has not looked at the tab since.
    let needsYou: Bool
    let prompts: [(date: Date, text: String)]
    let ticket: URL?
    /// The Ghostty window its tab is in; nil when closed or when its tab cannot be found.
    var windowId: String? = nil
    /// 1-based place of its tab among the terminals of its window.
    var tab: Int? = nil
    var isLord = false

    var isLive: Bool { status != nil }
    var isStale: Bool { isLive && Date().timeIntervalSince(lastInteraction) > Self.staleAfter }
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var rows: [Row] = []
    /// Sessions that were open when Ghostty last exited and have not been reopened yet.
    @Published private(set) var pending: [String] = []
    @Published private(set) var restoring = false
    @Published private(set) var ghosttyRunning = false
    @Published private(set) var automationBlocked = false
    @Published var autoRestore: Bool { didSet { if !isDemo { UserDefaults.standard.set(autoRestore, forKey: "autoRestore") } } }
    @Published var launchAtLogin: Bool { didSet { if !isDemo { applyLaunchAtLogin() } } }
    private var isDemo = false

    var liveCount: Int { rows.filter(\.isLive).count }
    var needsYouCount: Int { rows.filter(\.needsYou).count }

    /// A shutdown kills the Claude processes a little before it kills Ghostty and us,
    /// so "open at shutdown" has to mean "seen shortly before the last heartbeat".
    private let grace: TimeInterval = 180
    private let keepClosedFor: TimeInterval = 14 * 24 * 3600

    private var state = SavedState()
    private var terminals: [GhosttyTerminal] = []
    private var history: [String: SessionHistory] = [:]
    private var live: [String: LiveSession] = [:]
    private var polling = false
    private var poweringOff = false
    private let data = ClaudeData()
    private let toggleSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)

    private let stateURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LordOfTheClaudes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    /// Made-up sessions for README screenshots: reads and writes nothing, and never talks to Ghostty.
    /// `groupNames` names the made-up windows, by window id.
    init(demoRows: [Row], groupNames: [String: String] = [:]) {
        autoRestore = true
        launchAtLogin = false
        isDemo = true
        rows = demoRows
        ghosttyRunning = true
        // Stand-in tabs, so `groups` finds the windows the rows say they are in.
        terminals = demoRows
            .compactMap { row in row.windowId.map { (row, $0) } }
            .sorted { ($0.1, $0.0.tab ?? 0) < ($1.1, $1.0.tab ?? 0) }
            .map { row, windowId in
                GhosttyTerminal(id: "demo-" + row.id, windowId: windowId, title: "✳ " + row.title, cwd: row.cwd)
            }
        state.records = demoRows.map { row in
            Record(id: row.id, cwd: row.cwd, title: row.title, lastSeen: Date(), lastInteraction: row.lastInteraction,
                   group: row.windowId.flatMap { groupNames[$0] }, isLord: row.isLord ? true : nil)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let firstRun = defaults.object(forKey: "autoRestore") == nil
        autoRestore = firstRun ? true : defaults.bool(forKey: "autoRestore")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if firstRun {
            defaults.set(true, forKey: "autoRestore")
            launchAtLogin = true  // useless after a reboot unless it starts by itself
        }

        if let saved = try? Data(contentsOf: stateURL),
           let decoded = try? JSONDecoder().decode(SavedState.self, from: saved) {
            state = decoded
        }

        // Lets a script open the panel: `pkill -USR1 -x LordOfTheClaudes`.
        signal(SIGUSR1, SIG_IGN)
        toggleSignal.setEventHandler { Panel.toggle() }
        toggleSignal.resume()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.freezeForShutdown() }
        }

        HotKey.register { Panel.toggle() }

        Task {
            while true {
                await poll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Polling

    private struct Snapshot {
        var ghosttyLaunch: Date?
        var running = false
        var live: [LiveSession] = []
        var titles: [String: String] = [:]
        var history: [String: SessionHistory] = [:]
        var ghostty: Ghostty.State?
    }

    private func poll() async {
        guard !isDemo, !polling else { return }
        polling = true
        defer { polling = false }

        let data = self.data
        let snapshot = await Task.detached { () -> Snapshot in
            var snap = Snapshot()
            guard let app = Ghostty.app else { return snap }
            snap.running = true
            snap.ghosttyLaunch = app.launchDate
            snap.live = ClaudeData.liveSessions()
            for session in snap.live {
                snap.titles[session.sessionId] = data.title(sessionId: session.sessionId, cwd: session.cwd)
            }
            snap.history = data.history()
            snap.ghostty = Ghostty.state()
            return snap
        }.value
        apply(snapshot)
    }

    private func apply(_ snap: Snapshot) {
        let now = Date()
        ghosttyRunning = snap.running
        terminals = snap.ghostty?.terminals ?? []
        automationBlocked = snap.running && snap.ghostty == nil
        if snap.running { history = snap.history }
        live = Dictionary(snap.live.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })

        if snap.running && !poweringOff {
            // Ghostty has started since we last saw it: whatever was open back then needs reopening.
            if let launch = snap.ghosttyLaunch, launch > state.heartbeat, state.heartbeat > .distantPast {
                let cutoff = state.heartbeat.addingTimeInterval(-grace)
                pending = state.records
                    .filter { live[$0.id] == nil && $0.lastSeen >= cutoff && $0.closedByUser != true }
                    .map(\.id)
                if autoRestore && !pending.isEmpty {
                    let ids = pending
                    Task { await restore(ids, intoRestoredTabs: true) }
                }
            }

            // Tabs are matched to sessions by title: Ghostty does not expose a tab's process.
            let frontTitle = snap.ghostty?.focusedId
                .flatMap { id in terminals.first { $0.id == id } }
                .flatMap { $0.looksLikeClaude ? $0.sessionTitle : nil }

            for session in snap.live {
                let existing = state.records.firstIndex { $0.id == session.sessionId }
                let lastPrompt = snap.history[session.sessionId]?.prompts.last
                let title = snap.titles[session.sessionId]
                    ?? existing.map { state.records[$0].title }
                    ?? lastPrompt?.text.split(separator: "\n").first.map { String($0.prefix(80)) }
                    ?? URL(fileURLWithPath: session.cwd).lastPathComponent

                var record = existing.map { state.records[$0] }
                    ?? Record(id: session.sessionId, cwd: session.cwd, title: title, lastSeen: now,
                              lastInteraction: session.updatedAt, seenAt: now)
                record.cwd = session.cwd
                record.title = title
                record.lastSeen = now
                record.closedByUser = nil
                if let lastPrompt { record.lastInteraction = lastPrompt.date }
                if let index = terminals.firstIndex(where: { $0.looksLikeClaude && $0.sessionTitle == title }) {
                    record.position = index
                }
                if record.seenAt == nil || frontTitle == title { record.seenAt = now }
                if record.group == nil, let windowId = terminal(titled: title)?.windowId {
                    // A session opened in a named window joins that group.
                    record.group = rows.first { $0.windowId == windowId && $0.id != record.id }
                        .flatMap { row in state.records.first { $0.id == row.id }?.group }
                }

                if let existing { state.records[existing] = record } else { state.records.append(record) }
            }
            state.heartbeat = now
            state.records.removeAll { now.timeIntervalSince($0.lastSeen) > keepClosedFor }
            save()
        }

        pending.removeAll { live[$0] != nil }
        rows = state.records
            .map { record in
                let session = live[record.id]
                let sessionHistory = history[record.id]
                let needsYou = session.map { $0.status != "busy" && $0.statusUpdatedAt > (record.seenAt ?? .distantFuture) } ?? false
                let terminal = session == nil ? nil : terminal(titled: record.title)
                let tab = terminal.flatMap { t in
                    terminals.filter { $0.windowId == t.windowId }.firstIndex { $0.id == t.id }.map { $0 + 1 }
                }
                return Row(
                    id: record.id, title: record.title, cwd: record.cwd,
                    status: session?.status, statusSince: session?.statusUpdatedAt,
                    lastInteraction: record.lastInteraction, needsYou: needsYou,
                    prompts: sessionHistory?.prompts ?? [],
                    ticket: Tickets.link(title: record.title) ?? sessionHistory?.link,
                    windowId: terminal?.windowId, tab: tab, isLord: session != nil && record.isLord == true
                )
            }
            .sorted { ($0.needsYou ? 1 : 0, $0.lastInteraction) > ($1.needsYou ? 1 : 0, $1.lastInteraction) }
    }

    // MARK: Groups

    /// A group is a Ghostty window: the sessions in its tabs.
    struct Group: Identifiable {
        let id: String  // the Ghostty window id
        let name: String
        let rows: [Row]
    }

    /// Tabs are matched to sessions by title: Ghostty does not expose a tab's process.
    private func terminal(titled title: String) -> GhosttyTerminal? {
        terminals.first { $0.looksLikeClaude && $0.sessionTitle == title }
    }

    /// Running sessions by window, in Ghostty's window order, each in tab order.
    /// Sessions whose tab cannot be found are not in any group.
    var groups: [Group] {
        var order: [String] = []
        for terminal in terminals where !order.contains(terminal.windowId) { order.append(terminal.windowId) }
        return order.compactMap { windowId in
            let members = rows.filter { $0.windowId == windowId }.sorted { ($0.tab ?? 0) < ($1.tab ?? 0) }
            return members.isEmpty ? nil : Group(id: windowId, name: groupName(of: members), rows: members)
        }
    }

    /// The name the user gave it, otherwise the directory most of its sessions are in.
    private func groupName(of members: [Row]) -> String {
        func commonest(_ names: [String]) -> String? {
            Dictionary(grouping: names, by: { $0 }).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
        }
        let given = members.compactMap { row in state.records.first { $0.id == row.id }?.group }
        return commonest(given) ?? commonest(members.map { URL(fileURLWithPath: $0.cwd).lastPathComponent }) ?? "Sessions"
    }

    func renameGroup(_ windowId: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let members = Set(rows.filter { $0.windowId == windowId }.map(\.id))
        for index in state.records.indices where members.contains(state.records[index].id) {
            state.records[index].group = name.isEmpty ? nil : name
        }
        save()
        objectWillChange.send()
    }

    /// Makes a session the lord of its window; a window has one lord.
    func makeLord(_ sessionId: String) {
        guard let windowId = rows.first(where: { $0.id == sessionId })?.windowId else { return }
        let members = Set(rows.filter { $0.windowId == windowId }.map(\.id))
        for index in state.records.indices where members.contains(state.records[index].id) {
            state.records[index].isLord = state.records[index].id == sessionId ? true : nil
        }
        save()
        Task { await poll() }
    }

    /// The running sessions sharing a window with this one, itself included, in tab order.
    func window(ofSession sessionId: String) -> [Row] {
        guard let windowId = rows.first(where: { $0.id == sessionId })?.windowId else { return [] }
        return groups.first { $0.id == windowId }?.rows ?? []
    }

    // MARK: Prompts

    /// Types a prompt into the session's tab and submits it. False when its tab cannot be found.
    @discardableResult
    func send(_ text: String, toSession sessionId: String) async -> Bool {
        guard !isDemo, let row = rows.first(where: { $0.id == sessionId }), row.isLive,
              let terminal = terminal(titled: row.title)
        else { return false }
        let sent = await Task.detached { Ghostty.send(text: text, toTerminal: terminal.id) }.value
        if sent { await poll() }
        return sent
    }

    /// Sends one prompt to every session in a window. Returns how many took it.
    @discardableResult
    func broadcast(_ text: String, toGroup windowId: String) async -> Int {
        var sent = 0
        for row in rows where row.windowId == windowId {
            if await send(text, toSession: row.id) { sent += 1 }
        }
        return sent
    }

    private func save() {
        guard !isDemo else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? encoder.encode(state) { try? encoded.write(to: stateURL, options: .atomic) }
    }

    private func freezeForShutdown() {
        poweringOff = true
        // The shutdown may be cancelled (an app refusing to quit), so do not stay frozen for ever.
        Task {
            try? await Task.sleep(for: .seconds(300))
            poweringOff = false
        }
    }

    // MARK: Actions

    func restorePending() { let ids = pending; Task { await restore(ids, intoRestoredTabs: true) } }

    func dismissPending() { pending = [] }

    func reopen(_ row: Row) { Task { await restore([row.id], intoRestoredTabs: false) } }

    func forget(_ row: Row) {
        state.records.removeAll { $0.id == row.id }
        rows.removeAll { $0.id == row.id }
        pending.removeAll { $0 == row.id }
        save()
    }

    func focus(_ row: Row) {
        let match = terminal(titled: row.title)
        Task.detached {
            if let match { Ghostty.focus(terminalId: match.id) } else { Ghostty.app?.activate() }
        }
    }

    /// Ends the Claude processes and closes their tabs. The sessions stay under "Recently closed".
    func close(_ rows: [Row]) {
        let targets = rows.compactMap { row -> (id: String, pid: pid_t, terminalId: String?)? in
            guard let session = live[row.id] else { return nil }
            // Only close the tab when the title identifies it beyond doubt.
            let tabs = terminals.filter { $0.looksLikeClaude && $0.sessionTitle == row.title }
            return (row.id, session.pid, tabs.count == 1 ? tabs[0].id : nil)
        }
        Task {
            let closed = await Task.detached { () -> [String] in
                var closed: [String] = []
                for target in targets {
                    kill(target.pid, SIGTERM)
                    var exited = false
                    for _ in 0..<25 where !exited {
                        try? await Task.sleep(for: .milliseconds(200))
                        exited = kill(target.pid, 0) != 0
                    }
                    guard exited else { continue }
                    closed.append(target.id)
                    if let terminalId = target.terminalId {
                        try? await Task.sleep(for: .milliseconds(500))  // let the shell prompt come back
                        Ghostty.close(terminalId: terminalId)
                    }
                }
                return closed
            }.value
            for index in state.records.indices where closed.contains(state.records[index].id) {
                state.records[index].closedByUser = true
            }
            save()
            await poll()
        }
    }

    /// `intoRestoredTabs`: put sessions back into the empty tabs Ghostty restored by itself.
    private func restore(_ ids: [String], intoRestoredTabs: Bool) async {
        guard !restoring, !ids.isEmpty else { return }
        restoring = true
        defer { restoring = false }

        let records = ids.compactMap { id in state.records.first { $0.id == id } }
        await Task.detached {
            // Only type into existing tabs just after Ghostty has started, when they are the empty
            // shells it restored. Later on a tab could be running anything, so open new ones.
            let justLaunched = Ghostty.app?.launchDate.map { Date().timeIntervalSince($0) < 900 } ?? false
            var free: [Int: GhosttyTerminal] = [:]  // by position
            if intoRestoredTabs && justLaunched {
                // Let Ghostty finish restoring its windows before counting tabs.
                var previous = -1
                for _ in 0..<15 {
                    let count = Ghostty.terminals()?.count ?? -1
                    if count >= 0 && count == previous { break }
                    previous = count
                    try? await Task.sleep(for: .seconds(2))
                }
                let nothingRunning = ClaudeData.liveSessions().isEmpty
                for (position, terminal) in (Ghostty.terminals() ?? []).enumerated()
                where nothingRunning || !terminal.looksLikeClaude {
                    free[position] = terminal
                }
            }

            let live = Set(ClaudeData.liveSessions().map(\.sessionId))
            let todo = records
                .filter { !live.contains($0.id) }
                .sorted { ($0.position ?? .max) < ($1.position ?? .max) }

            // First the tab each session used to be in, then any spare tab in the same directory.
            var tabs: [String: GhosttyTerminal] = [:]
            for record in todo {
                if let position = record.position, let terminal = free[position],
                   Self.samePath(terminal.cwd, record.cwd) {
                    tabs[record.id] = terminal
                    free[position] = nil
                }
            }
            for record in todo where tabs[record.id] == nil {
                if let position = free.keys.sorted().first(where: { Self.samePath(free[$0]!.cwd, record.cwd) }) {
                    tabs[record.id] = free.removeValue(forKey: position)
                }
            }

            for record in todo {
                if let terminal = tabs[record.id] {
                    _ = Ghostty.resume(sessionId: record.id, inTerminal: terminal.id)
                } else {
                    _ = Ghostty.resumeInNewTab(sessionId: record.id, cwd: record.cwd)
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }.value

        pending.removeAll { ids.contains($0) }
    }

    private nonisolated static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin, service.status != .enabled { try service.register() }
            if !launchAtLogin, service.status == .enabled { try service.unregister() }
        } catch {
            NSLog("Lord of the Claudes: launch at login failed: \(error.localizedDescription)")
        }
    }
}
