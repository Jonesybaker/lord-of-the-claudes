import Carbon.HIToolbox
import SwiftUI


struct MenuBarApp: App {
    @StateObject private var store = Store()

    private var icon: String {
        if store.needsYouCount > 0 { return "bell.badge" }
        return store.pending.isEmpty ? "rectangle.stack" : "rectangle.stack.badge.plus"
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            Image(systemName: icon)
            // "2/20": two of twenty sessions are waiting for you.
            Text(store.needsYouCount > 0 ? "\(store.needsYouCount)/\(store.liveCount)" : "\(store.liveCount)")
        }
        .menuBarExtraStyle(.window)
    }
}

/// "now", "12m", "23h", "5d", "2w".
func shortAge(_ date: Date) -> String {
    let age = Date().timeIntervalSince(date)
    switch age {
    case ..<60: return "now"
    case ..<3600: return "\(Int(age / 60))m"
    case ..<86400: return "\(Int(age / 3600))h"
    case ..<(14 * 86400): return "\(Int(age / 86400))d"
    default: return "\(Int(age / (7 * 86400)))w"
    }
}

/// Catches key presses in the panel before the search field's text editor swallows them
/// (it treats the arrow keys as cursor movement).
final class PanelKeys {
    var handler: ((UInt16) -> Bool)?

    init() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window?.className.contains("MenuBarExtraWindow") == true,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  self?.handler?(event.keyCode) == true
            else { return event }
            return nil
        }
    }
}

private struct ContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    @ObservedObject var store: Store
    @State private var query = ""
    @State private var selection = 0
    @State private var expanded: Set<String>
    @State private var confirmingStale = false
    @State private var listHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @State private var keys = PanelKeys()

    init(store: Store, expanded: Set<String> = []) {
        self.store = store
        _expanded = State(initialValue: expanded)
    }

    private func matches(_ row: Row) -> Bool {
        query.isEmpty || row.title.localizedCaseInsensitiveContains(query) || row.cwd.localizedCaseInsensitiveContains(query)
    }

    private var live: [Row] { store.rows.filter { $0.isLive && matches($0) } }
    private var closed: [Row] { Array(store.rows.filter { !$0.isLive && matches($0) }.prefix(15)) }
    /// Everything on screen in display order; `selection` indexes into this.
    private var visible: [Row] { live + closed }
    private var stale: [Row] { store.rows.filter(\.isStale) }

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
            resetForOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in resetForOpen() }
        .onChange(of: query) { selection = 0 }
    }

    private func resetForOpen() {
        query = ""
        selection = 0
        confirmingStale = false
        // Focus only sticks once the window is key, which is a beat after it appears.
        DispatchQueue.main.async { searchFocused = true }
    }

    /// Navigation keys, whatever has keyboard focus inside the panel. Returns true if the key was used.
    private func handleKey(_ keyCode: UInt16) -> Bool {
        let selected = visible.indices.contains(selection) ? visible[selection] : nil
        switch Int(keyCode) {
        case kVK_DownArrow: moveSelection(1)
        case kVK_UpArrow: moveSelection(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter: if let selected { activate(selected) }
        case kVK_Tab: if let selected { toggleExpanded(selected) }
        case kVK_RightArrow: if let selected { expanded.insert(selected.id) }
        case kVK_LeftArrow: if let selected { expanded.remove(selected.id) }
        case kVK_Escape: Panel.close()
        default: return false
        }
        return true
    }

    private func activate(_ row: Row) {
        if row.isLive {
            store.focus(row)
            Panel.close()
        } else {
            store.reopen(row)
        }
    }

    private func toggleExpanded(_ row: Row) {
        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
    }

    private func moveSelection(_ delta: Int) {
        guard !visible.isEmpty else { return }
        selection = min(max(selection + delta, 0), visible.count - 1)
    }

    private var header: some View {
        HStack {
            Text("Claude sessions").font(.headline)
            Text(HotKey.display).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            if store.needsYouCount > 0 {
                Text("\(store.needsYouCount) waiting for you").font(.subheadline).foregroundStyle(.orange)
            }
            Text(store.ghosttyRunning ? "\(store.liveCount) open" : "Ghostty is not running")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }

    private var search: some View {
        TextField("Filter. Return jumps to the session, Right shows its prompts", text: $query)
            .textFieldStyle(.roundedBorder)
            .focused($searchFocused)
            .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func sessionRow(_ row: Row, index: Int) -> some View {
        SessionRow(
            row: row, selected: index == selection, expanded: expanded.contains(row.id),
            activate: { activate(row) },
            toggleExpanded: { toggleExpanded(row) },
            remove: { if row.isLive { store.close([row]) } else { store.forget(row) } }
        )
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(live.enumerated()), id: \.element.id) { index, row in
                        sessionRow(row, index: index)
                    }
                    if !closed.isEmpty {
                        Text("RECENTLY CLOSED")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                        ForEach(Array(closed.enumerated()), id: \.element.id) { index, row in
                            sessionRow(row, index: live.count + index)
                        }
                    }
                    if visible.isEmpty {
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
                if visible.indices.contains(selection) { proxy.scrollTo(visible[selection].id) }
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

/// How long since the last prompt, as a badge that fades as the session goes stale.
struct AgeBadge: View {
    let date: Date
    let live: Bool

    /// Strongest within the hour, then stepping down: today, last 3 days, this week, older.
    private var strength: Double {
        switch Date().timeIntervalSince(date) {
        case ..<3600: return 1
        case ..<86400: return 0.65
        case ..<(3 * 86400): return 0.4
        case ..<Row.staleAfter: return 0.22
        default: return 0.1
        }
    }

    var body: some View {
        Text(shortAge(date))
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(live && strength > 0.5 ? Color.white : Color.primary.opacity(0.75))
            .frame(width: 34, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(live ? Color.accentColor.opacity(strength) : Color.gray.opacity(0.15))
            )
    }
}

struct SessionRow: View {
    let row: Row
    let selected: Bool
    let expanded: Bool
    let activate: () -> Void
    let toggleExpanded: () -> Void
    /// Closes a running session, or forgets a closed one.
    let remove: () -> Void
    @State private var hovering = false

    private var shortCwd: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return row.cwd.hasPrefix(home) ? "~" + row.cwd.dropFirst(home.count) : row.cwd
    }

    private func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private var subtitle: String {
        let prompt = row.prompts.last.map { oneLine($0.text) } ?? shortCwd
        if row.needsYou, let since = row.statusSince { return "Finished \(shortAge(since)) ago · \(prompt)" }
        if row.status == "busy" { return "Working · \(prompt)" }
        return prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if expanded { details }
        }
        .background(selected ? Color.accentColor.opacity(0.25) : hovering ? Color.primary.opacity(0.08) : .clear)
        .overlay(alignment: .leading) {
            if row.needsYou { Rectangle().fill(.orange).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if row.isLive { activate() } }
        .id(row.id)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            AgeBadge(date: row.lastInteraction, live: row.isLive)
                .help("Last prompt " + row.lastInteraction.formatted(date: .abbreviated, time: .shortened))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if row.needsYou {
                        Image(systemName: "bell.fill").font(.caption).foregroundStyle(.orange)
                    }
                    Text(row.title).lineLimit(1)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !row.isLive {
                Button("Reopen", action: activate).controlSize(.small)
            }
            if hovering {
                Button(action: remove) { Image(systemName: "xmark") }
                    .help(row.isLive ? "Close this session and its tab (it stays under Recently closed)" : "Forget this session")
            }
            if let ticket = row.ticket {
                Button { NSWorkspace.shared.open(ticket) } label: { Image(systemName: "ticket") }
                    .help(ticket.absoluteString)
            }
            Button(action: toggleExpanded) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12)
            }
            .help("Show recent prompts")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(shortCwd + (row.status.map { " · \($0)" } ?? " · closed"))
                .font(.caption).foregroundStyle(.secondary)
            if row.prompts.isEmpty {
                Text("No prompts in Claude's history for this session.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(row.prompts.enumerated().reversed()), id: \.offset) { _, prompt in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(shortAge(prompt.date))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    Text(prompt.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.callout).lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 56).padding(.trailing, 12).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
