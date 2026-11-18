import Foundation

/// A running session as the overseer names it: its group (Ghostty window) and tab.
struct SessionPlace: Equatable, Sendable {
    let rowId: String
    /// The window's name as the sidebar shows it; "Other" when its tab cannot be found.
    let group: String
    let windowId: String?
    let tab: Int?
    let title: String
    let cwd: String
    /// In an excluded directory: the overseer is never told of it.
    var isPrivate = false

    /// "Shop, tab 2", or "Other".
    var spot: String { tab.map { "\(group), tab \($0)" } ?? group }
}

/// A session as the overseer wrote it in a proposal or a link: any of its group, tab and title.
struct ProposedTarget: Equatable, Sendable {
    var group: String?
    var tab: Int?
    var title: String?

    init(group: String? = nil, tab: Int? = nil, title: String? = nil) {
        self.group = group?.trimmedNonEmpty
        self.tab = tab
        self.title = title?.trimmedNonEmpty
    }

    /// From a link's "session:Shop 2/3" reference and its text.
    init(reference: String, label: String) {
        let reference = reference.trimmingCharacters(in: .whitespaces)
        if let match = reference.wholeMatch(of: #/(?<group>.*?)\s*[/,]\s*(?:tab\s*)?(?<tab>\d+)/#) {
            self.init(group: String(match.group), tab: Int(match.tab), title: label)
        } else {
            self.init(group: reference, title: label)
        }
    }

    /// The model is told to write numbers, but "2" and "tab 2" are read too.
    init?(json: Any) {
        guard let object = json as? [String: Any] else { return nil }
        let tab = (object["tab"] as? Int) ?? (object["tab"] as? String).flatMap { Int($0.filter(\.isNumber)) }
        self.init(group: object["group"] as? String, tab: tab, title: object["title"] as? String)
        if group == nil && self.tab == nil && title == nil { return nil }
    }
}

/// Finds the running session a proposed target means. Never guesses: a tab whose title disagrees with
/// the one the overseer named is not taken, as tabs renumber when one closes.
enum TargetMatch {
    enum Outcome: Equatable {
        case one(SessionPlace)
        case several([SessionPlace])
        case none
    }

    static func find(_ target: ProposedTarget, in places: [SessionPlace]) -> Outcome {
        let inGroup = target.group.map { group in places.filter { same($0.group, group) } } ?? places
        if let tab = target.tab {
            let spot = inGroup.filter { $0.tab == tab }
            if spot.count == 1, target.title.map({ agrees(spot[0].title, $0) }) ?? true { return .one(spot[0]) }
        }
        if let title = target.title {
            // A renamed group still finds its sessions by title.
            let pools = target.group == nil ? [places] : [inGroup, places]
            for matches in [{ (p: SessionPlace) in same(p.title, title) }, { $0.title.localizedCaseInsensitiveContains(title) }] {
                for pool in pools {
                    let found = pool.filter(matches)
                    if found.count == 1 { return .one(found[0]) }
                    if found.count > 1 { return .several(found) }
                }
            }
        } else if target.tab == nil, target.group != nil, inGroup.count == 1 {
            return .one(inGroup[0])
        }
        return .none
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// The overseer may shorten a title, so either containing the other agrees.
    private static func agrees(_ title: String, _ named: String) -> Bool {
        same(title, named) || title.localizedCaseInsensitiveContains(named) || named.localizedCaseInsensitiveContains(title)
    }
}

/// What the overseer offers to do. Nothing happens until the user confirms it on a routing card.
enum Proposal: Equatable {
    case send(targets: [ProposedTarget], prompt: String)
    case newSession(group: String?, cwd: String, prompt: String)
    /// Which session: to send the prompt to, or with no prompt, to go to.
    case choose(question: String?, candidates: [ProposedTarget], prompt: String?)
    /// Bring a session's tab to the front, for the user to look at themselves. Several are a "which one?".
    case goTo(targets: [ProposedTarget])

    static let goToActions: Set<String> = ["goto", "go_to", "go-to", "go"]

    init?(json: Any) {
        guard let object = json as? [String: Any], let action = (object["action"] as? String)?.lowercased() else { return nil }
        let targets = { (key: String) in (object[key] as? [Any] ?? []).compactMap(ProposedTarget.init(json:)) }
        let prompt = (object["prompt"] as? String)?.trimmedNonEmpty
        if Self.goToActions.contains(action) {
            let found = object["target"].flatMap(ProposedTarget.init(json:)).map { [$0] } ?? targets("targets")
            guard !found.isEmpty else { return nil }
            self = .goTo(targets: found)
            return
        }
        switch action {
        case "send":
            let found = targets("targets")
            guard let prompt, !found.isEmpty else { return nil }
            self = .send(targets: found, prompt: prompt)
        case "new":
            guard let prompt, let cwd = (object["cwd"] as? String)?.trimmedNonEmpty else { return nil }
            self = .newSession(group: (object["group"] as? String)?.trimmedNonEmpty, cwd: cwd, prompt: prompt)
        case "choose":
            let found = targets("candidates")
            guard !found.isEmpty else { return nil }
            self = .choose(question: (object["question"] as? String)?.trimmedNonEmpty, candidates: found, prompt: prompt)
        default:
            return nil
        }
    }

    /// A go-to or send naming one session, under words that link two or more, is a guess: it becomes a
    /// choice between them. The overseer is told to choose itself; this holds when it does not.
    func checked(against text: String, places: [SessionPlace]) -> Proposal {
        let target: ProposedTarget
        let prompt: String?
        switch self {
        case .goTo(let targets) where targets.count == 1: (target, prompt) = (targets[0], nil)
        case .send(let targets, let words) where targets.count == 1: (target, prompt) = (targets[0], words)
        default: return self
        }
        var seen = Set<String>()
        var linked = AnswerText.references(in: text).compactMap { reference -> SessionPlace? in
            guard case .one(let place) = TargetMatch.find(reference, in: places) else { return nil }
            return place
        }.filter { seen.insert($0.rowId).inserted }
        guard linked.count > 1 else { return self }
        if case .one(let place) = TargetMatch.find(target, in: places), !seen.contains(place.rowId) { linked.insert(place, at: 0) }
        return .choose(question: nil, candidates: linked.map { ProposedTarget(group: $0.group, tab: $0.tab, title: $0.title) },
                       prompt: prompt)
    }
}

/// An overseer reply split into the words to show and the proposal at its end, if any.
struct OverseerAnswer: Equatable {
    let text: String
    let proposal: Proposal?
    /// It wrote a proposal block that could not be read, so nothing is offered.
    let unreadableProposal: Bool

    /// Reads a ```lotc block, or a ```json one, or a bare {"action": ...} at the very end. Anything
    /// it cannot read stays out of the text, so raw JSON never shows, and offers nothing.
    static func parse(_ raw: String) -> OverseerAnswer {
        var text = raw
        var proposal: Proposal?
        var sawBlock = false
        let fenced = raw.matches(of: #/```[ \t]*(?<tag>lotc|json)?[ \t]*\n(?<body>[\s\S]*?)\n?[ \t]*```/#)
        for match in fenced.reversed() {
            let body = String(match.body)
            guard match.tag == "lotc" || body.contains("\"action\"") else { continue }
            sawBlock = true
            if let block = text.range(of: String(raw[match.range])) { text.removeSubrange(block) }
            if proposal == nil { proposal = decode(body) }
        }
        if !sawBlock, let start = raw.firstRange(of: #/\{\s*"action"/#)?.lowerBound,
           raw[start...].trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}") {
            sawBlock = true
            proposal = decode(String(raw[start...]))
            text = String(raw[..<start])
        }
        return OverseerAnswer(text: text.trimmingCharacters(in: .whitespacesAndNewlines), proposal: proposal,
                              unreadableProposal: sawBlock && proposal == nil)
    }

    /// The part of a reply still streaming in that is meant to be read: up to any proposal block,
    /// without a half-written fence at the end.
    static func visibleWhileStreaming(_ partial: String) -> String {
        var text = partial
        if let fence = text.range(of: "```") { text = String(text[..<fence.lowerBound]) }
        if let bare = text.firstRange(of: #/\n\s*\{\s*"/#) { text = String(text[..<bare.lowerBound]) }
        while text.hasSuffix("`") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ body: String) -> Proposal? {
        guard let data = body.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return Proposal(json: json)
    }
}

/// The overseer's words with each [title](session:Shop/2) made a link that jumps to that tab.
enum AnswerText {
    static let scheme = "lotc-session"

    private static var link: Regex<(Substring, label: Substring, reference: Substring)> {
        #/\[(?<label>[^\]\n]+)\]\(session:(?<reference>[^)\n]*)\)/#
    }

    /// Markdown in which every session the overseer named, and that is still running, links to
    /// lotc-session://<session id>. One it named that cannot be found keeps its words without a link.
    static func linked(_ text: String, places: [SessionPlace]) -> String {
        text.replacing(link) { match in
            let label = String(match.label)
            guard case .one(let place) = TargetMatch.find(ProposedTarget(reference: String(match.reference), label: label), in: places)
            else { return label }
            return "[\(label)](\(scheme)://\(place.rowId))"
        }
    }

    /// Every session the overseer linked, in order.
    static func references(in text: String) -> [ProposedTarget] {
        text.matches(of: link).map { ProposedTarget(reference: String($0.reference), label: String($0.label)) }
    }

    /// The words without a sentence promising the app will ask which session, for an answer no "which one?"
    /// card follows. Unchanged when that sentence is all there is.
    static func withoutPromisedChoice(_ text: String) -> String {
        let promise = #/[^.!?\n]*\bthe app (?:will |would |can )?(?:asks?|let you (?:pick|choose))\b[^.!?\n]*[.!?]?/#.ignoresCase()
        return text.replacing(promise, with: "").trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty ?? text
    }

    /// The words alone, each link's text kept: for a one-line preview.
    static func plain(_ text: String) -> String {
        text.replacing(#/\[(?<label>[^\]\n]+)\]\([^)\n]*\)/#) { String($0.label) }
    }

    static func attributed(_ text: String, places: [SessionPlace]) -> AttributedString {
        let markdown = linked(text, places: places)
        return (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    /// The session id a link points at, or nil for any other link.
    static func sessionId(in url: URL) -> String? {
        url.scheme == scheme ? url.host() : nil
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
