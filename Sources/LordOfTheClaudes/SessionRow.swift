import LotcKit
import SwiftUI

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
            // White only on the solid badge: on a paler one it is unreadable in the light theme.
            .foregroundStyle(live && strength == 1 ? Color.white : Color.primary.opacity(0.75))
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
    /// Nil when it cannot be made lord: closed, in no window, or lord already.
    let makeLord: (() -> Void)?
    @Binding var replyText: String
    let replyNote: SendNote?
    let sendReply: () -> Void
    /// The digest's earlier steps are on show.
    @Binding var historyOpen: Bool
    var focus: FocusState<PanelField?>.Binding
    @State private var hovering = false

    private var shortCwd: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return row.cwd.hasPrefix(home) ? "~" + row.cwd.dropFirst(home.count) : row.cwd
    }

    private func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private var subtitle: String {
        if row.needsYou, let since = row.statusSince { return "Finished \(shortAge(since)) ago · \(doing)" }
        if row.status == "busy" { return "Working · \(doing)" }
        return doing
    }

    /// What it is blocked on, else where it has got to, else the last prompt. A prompt newer than the
    /// digest is the newer news: the digest is from before Claude took it up.
    private var doing: String {
        let prompt = row.prompts.last
        if let digest = row.digest, prompt.map({ $0.date <= digest.at }) ?? true {
            return digest.blockedOn.map { "Needs you: " + $0 } ?? digest.state
        }
        return prompt.map { oneLine($0.text) } ?? shortCwd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Only the summary jumps to the tab and has the menu: the details hold selectable text and the reply field.
            summary
                .contentShape(Rectangle())
                .onTapGesture { if row.isLive { activate() } }
                .contextMenu {
                    if let makeLord { Button("Make lord of this group", action: makeLord) }
                }
            if expanded { details }
        }
        .background(selected ? Color.accentColor.opacity(0.25) : hovering ? Color.primary.opacity(0.08) : .clear)
        .overlay(alignment: .leading) {
            if row.needsYou { Rectangle().fill(Color.waiting).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .id(row.id)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            AgeBadge(date: row.lastInteraction, live: row.isLive)
                .help("Last prompt " + row.lastInteraction.formatted(date: .abbreviated, time: .shortened))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if row.needsYou {
                        Image(systemName: "bell.fill").font(.caption).foregroundStyle(Color.waiting)
                            .accessibilityLabel("Waiting for you")
                    }
                    if row.isLord {
                        Image(systemName: "crown.fill").font(.caption).foregroundStyle(Color.lord)
                            .help("Lord of this group")
                            .accessibilityLabel("Lord of this group")
                    }
                    Text(row.title).lineLimit(1)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(row.isLive ? "Return jumps to its tab. ⌘R replies without leaving the panel." : "Return reopens it.")
            Spacer(minLength: 8)
            if !row.isLive {
                Button("Reopen", action: activate).controlSize(.small)
            }
            if hovering {
                Button(action: remove) { Image(systemName: "xmark") }
                    .help(row.isLive ? "Close this session and its tab (it stays under Recently closed)" : "Forget this session")
                    .accessibilityLabel(row.isLive ? "Close this session and its tab" : "Forget this session")
            }
            if let ticket = row.ticket {
                Button { NSWorkspace.shared.open(ticket) } label: { Image(systemName: "ticket") }
                    .help(ticket.absoluteString)
                    .accessibilityLabel("Open the ticket")
            }
            Button(action: toggleExpanded) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12)
            }
            .help(expanded ? "Hide recent prompts" : "Show recent prompts and reply")
            .accessibilityLabel(expanded ? "Hide recent prompts" : "Show recent prompts and reply")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(shortCwd + (row.status.map { " · \($0)" } ?? " · closed"))
                .font(.caption).foregroundStyle(.secondary)
            if let digest = row.digest {
                DigestView(digest: digest, earlier: row.digestHistory.filter { $0 != digest }.reversed(),
                           historyOpen: $historyOpen)
            }
            if row.isLive { reply }
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

    /// Types a prompt into the session's tab without leaving the panel.
    private var reply: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("Send a prompt", text: $replyText)
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: .reply(sessionId: row.id))
                .onSubmit(sendReply)
                .help("Return types it into the session's tab. Esc leaves the field.")
            if let replyNote { SendNoteView(note: replyNote) }
        }
        .padding(.vertical, 2)
    }
}

/// The observer's three lines on a session, and the steps before them behind a disclosure.
struct DigestView: View {
    let digest: Digest
    /// Newest first.
    let earlier: [Digest]
    @Binding var historyOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                line("Goal", digest.goal)
                line("Now", digest.state)
                if let blockedOn = digest.blockedOn { line("Blocked on", blockedOn, labelColour: .waiting) }
            }
            Text("Summarised \(shortAge(digest.at) == "now" ? "just now" : shortAge(digest.at) + " ago")")
                .font(.caption).foregroundStyle(.secondary)
            if !earlier.isEmpty { history }
        }
        .padding(.vertical, 2)
    }

    private func line(_ label: String, _ text: String, labelColour: Color? = nil) -> some View {
        GridRow {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(labelColour.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .gridColumnAlignment(.trailing)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { historyOpen.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: historyOpen ? "chevron.down" : "chevron.right").frame(width: 10)
                    Text("Earlier (\(earlier.count))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(historyOpen ? "Hide what it did before" : "Show what it did before")
            .accessibilityLabel(historyOpen ? "Hide earlier steps" : "Show \(earlier.count) earlier steps")
            if historyOpen {
                ForEach(Array(earlier.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(shortAge(step.at))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        Text(step.state).font(.caption).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
