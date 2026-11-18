import SwiftUI

/// A proposal from the overseer, waiting for the user: send a prompt to sessions, start a new one, or
/// pick which session was meant. Its prompt can be edited before Send.
struct RoutingCard: Identifiable, Equatable {
    enum Kind: Equatable {
        /// `missing` names the targets that could not be found; they get nothing.
        case send([SessionPlace], missing: [String])
        case newSession(cwd: String, group: String?, windowId: String?)
        case choose(question: String, candidates: [SessionPlace])
        /// Brings one session's tab to the front. Several are a "which one?"; none, a session not found.
        case goTo([SessionPlace], missing: [String])
    }

    /// See PermissionQueue.armingDelay.
    static let armingDelay: TimeInterval = 0.6

    let id = UUID()
    var kind: Kind
    var prompt: String
    var shownAt = Date()
    var sending = false
    /// Images that go with the prompt, as file paths at its end. The user's, from the message that asked for it.
    var images: [AttachedImage] = []
    /// Offered by the app for a private session, not by the overseer: what becomes of it is never told to the overseer.
    var isPrivate = false

    var isArmed: Bool { Date().timeIntervalSince(shownAt) >= Self.armingDelay }

    /// Its Send, Start or Go can be pressed: something to act on, and a prompt where one is needed.
    var canSend: Bool {
        if case .goTo(let places, _) = kind { return places.count == 1 }
        guard prompt.trimmedNonEmpty != nil else { return false }
        switch kind {
        case .send(let places, _): return !places.isEmpty
        case .newSession(let cwd, _, _): return Self.isDirectory(cwd)
        case .choose, .goTo: return false
        }
    }

    var isGoTo: Bool { if case .goTo = kind { true } else { false } }

    /// Lists sessions to pick from.
    var asksWhich: Bool {
        switch kind {
        case .choose: true
        case .goTo(let places, _): places.count > 1
        default: false
        }
    }

    var headline: String {
        switch kind {
        case .send(let places, _) where places.isEmpty: return "Could not find that session"
        case .send(let places, _): return "Send to " + places.map { "\($0.spot), \($0.title)" }.formatted(.list(type: .and))
        case .newSession(_, let group, _): return "Start a new session" + (group.map { " in \($0)" } ?? "")
        case .choose(let question, _): return question
        case .goTo(let places, _) where places.isEmpty: return "Could not find that session"
        case .goTo(let places, _) where places.count == 1: return "Go to \(places[0].spot), \(places[0].title)"
        case .goTo: return "Which session?"
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
        case .choose(let question, let candidates, let prompt?):
            let found = unique(candidates.flatMap { resolve($0, in: places) })
            if found.count == 1 { return RoutingCard(kind: .send(found, missing: []), prompt: prompt) }
            return RoutingCard(kind: found.isEmpty ? .send([], missing: candidates.map(describe))
                                                   : .choose(question: question ?? "Which session?", candidates: found),
                               prompt: prompt)
        case .choose(_, let targets, nil), .goTo(let targets):
            let found = unique(targets.flatMap { resolve($0, in: places) })
            return RoutingCard(kind: .goTo(found, missing: found.isEmpty ? targets.map(describe) : []), prompt: "")
        }
    }

    /// Every running session a target could mean.
    private static func resolve(_ target: ProposedTarget, in places: [SessionPlace]) -> [SessionPlace] {
        switch TargetMatch.find(target, in: places) {
        case .one(let place): [place]
        case .several(let several): several
        case .none: []
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
            && a.images == b.images && a.isPrivate == b.isPrivate
    }
}

/// A card with a prompt takes dropped images; one without leaves them to the composer.
private struct CardDrops: ViewModifier {
    let takes: Bool
    @Binding var images: [AttachedImage]
    @Binding var dropping: Bool

    func body(content: Content) -> some View {
        if takes { content.takesDroppedImages(into: $images, isTargeted: $dropping) } else { content }
    }
}

/// The card on screen. Return sends, starts or goes, and Esc cancels, while it has the keyboard (MainView's keys).
struct RoutingCardView: View {
    @Binding var card: RoutingCard
    let send: () -> Void
    let cancel: () -> Void
    let choose: (SessionPlace) -> Void
    var focus: FocusState<MainField?>.Binding
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                Text(card.headline).font(.callout.weight(.semibold)).lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            details
            ForEach(candidates, id: \.rowId) { place in
                Button { choose(place) } label: {
                    Text("\(place.spot): \(place.title)").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            if card.hasPrompt {
                prompt
                if !card.images.isEmpty { images }
            }
            HStack(spacing: 8) {
                if card.sending {
                    ProgressView().controlSize(.small)
                    Text(card.isGoTo ? "Going..." : "Sending...").font(.caption).foregroundStyle(.secondary)
                } else if card.canSend {
                    Text(card.isGoTo ? "Return goes there." : "Return sends.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel).help("Esc cancels too")
                if card.canSend || card.sending {
                    Button(actionTitle, action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(card.sending)
                        .help(card.isGoTo ? "Brings its Ghostty tab to the front" : "Return sends it too, while the prompt has the keyboard")
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.5)))
        .modifier(CardDrops(takes: card.hasPrompt && !card.sending, images: $card.images, dropping: $dropping))
        .overlay { if dropping { DropHighlight() } }
    }

    private var actionTitle: String {
        switch card.kind {
        case .newSession: "Start"
        case .goTo: "Go"
        default: "Send"
        }
    }

    private var candidates: [SessionPlace] {
        switch card.kind {
        case .choose(_, let candidates): candidates
        case .goTo(let places, _) where places.count > 1: places
        default: []
        }
    }

    private var icon: String {
        switch card.kind {
        case .send: "paperplane"
        case .newSession: "plus.rectangle.on.rectangle"
        case .choose: "questionmark.circle"
        case .goTo: "arrow.up.forward.app"
        }
    }

    @ViewBuilder private var details: some View {
        switch card.kind {
        case .send(let places, let missing), .goTo(let places, let missing):
            if !missing.isEmpty {
                Text((places.isEmpty ? "No running session matches " : "Not found, so not sent: ") + missing.joined(separator: "; ") + ".")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .newSession(let cwd, _, let windowId):
            Text(SessionText.shortPath(cwd) + (windowId == nil ? " · opens in the front window" : ""))
                .font(.caption).foregroundStyle(.secondary)
            if !card.canSend && card.prompt.trimmedNonEmpty != nil {
                Text("There is no such directory.").font(.caption).foregroundStyle(Color.waiting)
            }
        case .choose:
            EmptyView()
        }
    }

    /// Exactly what goes with the prompt, to take off before sending.
    private var images: some View {
        VStack(alignment: .leading, spacing: 4) {
            AttachmentStrip(images: $card.images, editable: !card.sending)
            Text(card.images.count == 1 ? "This image goes with it: its path is added at the end of the prompt."
                                        : "These \(card.images.count) images go with it: their paths are added at the end of the prompt.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var prompt: some View {
        TextField("Prompt", text: $card.prompt.takingImagePaths(into: $card.images), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...6)
            .focused(focus, equals: .proposal)
            .disabled(card.sending)
            .accessibilityLabel("Prompt to send. Edit it before sending.")
    }
}
