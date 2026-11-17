import SwiftUI

/// A proposal from the overseer, waiting for the user: send a prompt to sessions, start a new one, or
/// pick which session was meant. Its prompt can be edited before Send.
struct RoutingCard: Identifiable, Equatable {
    enum Kind: Equatable {
        /// `missing` names the targets that could not be found; they get nothing.
        case send([SessionPlace], missing: [String])
        case newSession(cwd: String, group: String?, windowId: String?)
        case choose(question: String, candidates: [SessionPlace])
    }

    /// See PermissionQueue.armingDelay.
    static let armingDelay: TimeInterval = 0.6

    let id = UUID()
    var kind: Kind
    var prompt: String
    var shownAt = Date()
    var sending = false

    var isArmed: Bool { Date().timeIntervalSince(shownAt) >= Self.armingDelay }

    var canSend: Bool {
        guard prompt.trimmedNonEmpty != nil else { return false }
        switch kind {
        case .send(let places, _): return !places.isEmpty
        case .newSession(let cwd, _, _): return Self.isDirectory(cwd)
        case .choose: return false
        }
    }

    var headline: String {
        switch kind {
        case .send(let places, _) where places.isEmpty: return "Could not find that session"
        case .send(let places, _): return "Send to " + places.map { "\($0.spot), \($0.title)" }.formatted(.list(type: .and))
        case .newSession(_, let group, _): return "Start a new session" + (group.map { " in \($0)" } ?? "")
        case .choose(let question, _): return question
        }
    }

    /// Resolves the overseer's proposal against the sessions running now.
    static func make(_ proposal: Proposal, places: [SessionPlace]) -> RoutingCard {
        switch proposal {
        case .send(let targets, let prompt):
            var found: [SessionPlace] = []
            var missing: [String] = []
            var ambiguous: [SessionPlace] = []
            for target in targets {
                switch TargetMatch.find(target, in: places) {
                case .one(let place): found.append(place)
                case .several(let candidates): ambiguous += candidates
                case .none: missing.append(describe(target))
                }
            }
            if !ambiguous.isEmpty && targets.count == 1 {
                return RoutingCard(kind: .choose(question: "Which session?", candidates: unique(ambiguous)), prompt: prompt)
            }
            return RoutingCard(kind: .send(unique(found), missing: missing + ambiguous.map(\.spot)), prompt: prompt)
        case .newSession(let group, let cwd, let prompt):
            let windowId = group.flatMap { name in places.first { $0.group.caseInsensitiveCompare(name) == .orderedSame }?.windowId }
            return RoutingCard(kind: .newSession(cwd: (cwd as NSString).expandingTildeInPath, group: group, windowId: windowId),
                               prompt: prompt)
        case .choose(let question, let candidates, let prompt):
            let found = unique(candidates.flatMap { target -> [SessionPlace] in
                switch TargetMatch.find(target, in: places) {
                case .one(let place): return [place]
                case .several(let several): return several
                case .none: return []
                }
            })
            if found.count == 1 { return RoutingCard(kind: .send(found, missing: []), prompt: prompt) }
            return RoutingCard(kind: found.isEmpty ? .send([], missing: candidates.map(describe))
                                                   : .choose(question: question ?? "Which session?", candidates: found),
                               prompt: prompt)
        }
    }

    private static func unique(_ places: [SessionPlace]) -> [SessionPlace] {
        var seen = Set<String>()
        return places.filter { seen.insert($0.rowId).inserted }
    }

    private static func describe(_ target: ProposedTarget) -> String {
        [target.group, target.tab.map { "tab \($0)" }, target.title.map { "\"\($0)\"" }].compactMap { $0 }.joined(separator: ", ")
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func == (a: RoutingCard, b: RoutingCard) -> Bool {
        a.id == b.id && a.kind == b.kind && a.prompt == b.prompt && a.shownAt == b.shownAt && a.sending == b.sending
    }
}

/// The card on screen. Return sends and Esc cancels while its prompt has the keyboard (PanelView's keys).
struct RoutingCardView: View {
    @Binding var card: RoutingCard
    let send: () -> Void
    let cancel: () -> Void
    let choose: (SessionPlace) -> Void
    var focus: FocusState<PanelField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                Text(card.headline).font(.callout.weight(.semibold)).lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            details
            if case .choose(_, let candidates) = card.kind {
                ForEach(candidates, id: \.rowId) { place in
                    Button { choose(place) } label: {
                        Text("\(place.spot): \(place.title)").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            prompt
            HStack(spacing: 8) {
                if card.sending {
                    ProgressView().controlSize(.small)
                    Text("Sending...").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel).help("Esc cancels too")
                if card.canSend || card.sending {
                    Button(isNew ? "Start" : "Send", action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(card.sending)
                        .help("Return sends it too, while the prompt has the keyboard")
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5)))
    }

    private var isNew: Bool { if case .newSession = card.kind { true } else { false } }

    private var icon: String {
        switch card.kind {
        case .send: "paperplane"
        case .newSession: "plus.rectangle.on.rectangle"
        case .choose: "questionmark.circle"
        }
    }

    @ViewBuilder private var details: some View {
        switch card.kind {
        case .send(let places, let missing):
            if !missing.isEmpty {
                Text((places.isEmpty ? "No running session matches " : "Not found, so not sent: ") + missing.joined(separator: "; ") + ".")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .newSession(let cwd, _, let windowId):
            Text(shortPath(cwd) + (windowId == nil ? " · opens in the front window" : ""))
                .font(.caption).foregroundStyle(.secondary)
            if !card.canSend && card.prompt.trimmedNonEmpty != nil {
                Text("There is no such directory.").font(.caption).foregroundStyle(Color.waiting)
            }
        case .choose:
            EmptyView()
        }
    }

    @ViewBuilder private var prompt: some View {
        if case .send(let places, _) = card.kind, places.isEmpty {
            EmptyView()
        } else {
            TextField("Prompt", text: $card.prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .focused(focus, equals: .proposal)
                .disabled(card.sending)
                .accessibilityLabel("Prompt to send. Edit it before sending.")
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
