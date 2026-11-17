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

/// One session in the sidebar, in two lines. A click shows it in the main area; a double click goes to its tab.
struct SessionRow: View {
    let row: Row
    /// Its detail is in the main area.
    let showing: Bool
    /// The arrows are on it.
    let highlighted: Bool
    /// Its window and tab, when the group heading does not say: "Shop, tab 2".
    let place: String?
    let model: WindowModel
    @State private var hovering = false

    private var subtitle: String {
        let doing = SessionText.doing(row)
        if row.needsYou, let since = row.statusSince { return "Finished \(shortAge(since)) ago · \(doing)" }
        if row.status == "busy" { return "Working · \(doing)" }
        return doing
    }

    var body: some View {
        HStack(spacing: 10) {
            AgeBadge(date: row.lastInteraction, live: row.isLive)
                .help("Last prompt " + row.lastInteraction.formatted(date: .abbreviated, time: .shortened))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    SessionMarks(row: row)
                    Text(row.title).lineLimit(1)
                    Spacer(minLength: 4)
                    if let place {
                        Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !row.isLive {
                Button("Reopen") { model.goTo(row) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(showing ? Color.accentColor.opacity(0.25) : highlighted ? Color.accentColor.opacity(0.14)
                    : hovering ? Color.primary.opacity(0.06) : .clear)
        .overlay(alignment: .leading) {
            if row.needsYou { Rectangle().fill(Color.waiting).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.show(row) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.goTo(row) })
        .onHover { hovering = $0 }
        .contextMenu { SessionMenu(row: row, model: model) }
        .help(row.isLive ? "Click for its detail. Double-click or Return goes to its tab." : "Click for its detail. Return reopens it.")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(showing ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: row.isLive ? "Go to tab" : "Reopen") { model.goTo(row) }
        .id(row.id)
    }
}

/// The bell and the crown in front of a session's title.
struct SessionMarks: View {
    let row: Row

    var body: some View {
        if row.needsYou {
            Image(systemName: "bell.fill").font(.caption).foregroundStyle(Color.waiting)
                .accessibilityLabel("Waiting for you")
        }
        if row.isLord {
            Image(systemName: "crown.fill").font(.caption).foregroundStyle(Color.lord)
                .help("Lord of its window")
                .accessibilityLabel("Lord of its window")
        }
        if row.isPrivate {
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                .help("Private: its directory is excluded, so it is never summarised, briefed or auto-approved")
                .accessibilityLabel("Private")
        }
    }
}

/// A session's right-click menu, in the sidebar and on its detail.
struct SessionMenu: View {
    let row: Row
    let model: WindowModel

    var body: some View {
        Button(row.isLive ? "Go to tab" : "Reopen") { model.goTo(row) }
        Button("Show details") { model.show(row) }
        Menu("Move to topic") { TopicMenu(row: row, model: model) }
        if row.isLive && row.windowId != nil && !row.isLord {
            Button("Make lord of its window") { model.store.makeLord(row.id) }
        }
        Divider()
        Button(row.isLive ? "Close session and tab" : "Forget") { model.close(row) }
    }
}

/// The topics a session can move to, a new one, and handing it back to the observer.
struct TopicMenu: View {
    let row: Row
    let model: WindowModel

    var body: some View {
        ForEach(model.topicChoices, id: \.self) { topic in
            Button(topic) { model.move(row, toTopic: topic) }
                .disabled(Topics.same(topic, row.topicName))
        }
        Divider()
        Button("New topic…") { model.namingTopicFor = row.id }
        if row.topicPinned {
            Button("Let the observer choose") { model.store.unpinTopic(row.id) }
        }
    }
}

/// How a session is described in a line.
enum SessionText {
    /// What it is blocked on, else where it has got to, else the last prompt. A prompt newer than the
    /// digest is the newer news: the digest is from before Claude took it up.
    static func doing(_ row: Row) -> String {
        if row.isPrivate { return "Private" }
        let prompt = row.prompts.last
        if let digest = row.digest, prompt.map({ $0.date <= digest.at }) ?? true {
            return digest.blockedOn.map { "Needs you: " + $0 } ?? digest.state
        }
        return prompt.map { oneLine($0.text) } ?? shortPath(row.cwd)
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// "Shop, tab 2", "Shop" or "no tab".
    static func place(_ row: Row, windowNames: [String: String]) -> String {
        guard let windowId = row.windowId, let name = windowNames[windowId] else { return "no tab" }
        return row.tab.map { "\(name), tab \($0)" } ?? name
    }
}
