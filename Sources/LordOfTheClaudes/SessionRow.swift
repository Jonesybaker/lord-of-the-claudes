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
