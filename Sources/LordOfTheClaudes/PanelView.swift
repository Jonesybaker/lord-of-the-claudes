import Carbon.HIToolbox
import SwiftUI

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
