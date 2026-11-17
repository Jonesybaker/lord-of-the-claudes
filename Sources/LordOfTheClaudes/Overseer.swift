import Foundation
import SwiftUI

/// Where the overseer keeps its things: beside state.json, or in a scratch folder for a sandboxed copy.
enum OverseerFiles {
    static let directory: URL = Sandbox.isOn
        ? FileManager.default.temporaryDirectory.appendingPathComponent("LordOfTheClaudes-sandbox")
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LordOfTheClaudes")
    static let conversation = directory.appendingPathComponent("overseer.json")
    static let settings = directory.appendingPathComponent("overseer-settings.json")
    /// The overseer's working directory. Sessions running here are the overseer's and never listed.
    static let workspace = directory.appendingPathComponent("overseer")

    static func isOverseer(cwd: String) -> Bool { TabMatch.samePath(cwd, workspace.path) }
}

/// overseer-settings.json, written with its defaults the first time the overseer is asked anything.
struct OverseerSettings: Codable, Equatable, Sendable {
    /// A Claude Code model alias or full name.
    var model = "sonnet"
    /// Claude Code's --effort; low keeps answers quick. Nil leaves it to Claude Code.
    var effort: String? = "low"
    /// The path of `claude`, when it is somewhere the app does not look.
    var claude: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? c.decodeIfPresent(String.self, forKey: .model))?.trimmedNonEmpty ?? model
        effort = (try? c.decodeIfPresent(String.self, forKey: .effort))?.trimmedNonEmpty
        claude = (try? c.decodeIfPresent(String.self, forKey: .claude))?.trimmedNonEmpty
    }

    static func load(from url: URL) -> OverseerSettings {
        if let data = try? Data(contentsOf: url) {
            return (try? JSONDecoder().decode(OverseerSettings.self, from: data)) ?? OverseerSettings()
        }
        let defaults = OverseerSettings()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(defaults).write(to: url, options: .atomic)
        return defaults
    }
}

struct OverseerMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user, overseer
        /// What the app did or could not do: a prompt sent, a proposal cancelled, an error.
        case note
    }

    var id = UUID()
    let role: Role
    let text: String
    var at = Date()
}

/// The chat as kept in overseer.json: the last `cap` messages and Claude Code's id for the conversation.
struct OverseerConversation: Codable, Equatable {
    static let cap = 60

    /// Nil until the first answer, and again after "New chat".
    var sessionId: String?
    var messages: [OverseerMessage] = []

    mutating func append(_ message: OverseerMessage, cap: Int = Self.cap) {
        messages.append(message)
        if messages.count > cap { messages.removeFirst(messages.count - cap) }
    }

    static func load(from url: URL) -> OverseerConversation {
        guard let data = try? Data(contentsOf: url) else { return OverseerConversation() }
        return (try? JSONDecoder().decode(OverseerConversation.self, from: data)) ?? OverseerConversation()
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// What the overseer is told: who it is once, then the current briefing with every message.
enum OverseerPrompt {
    static let system = """
        You are the overseer in Lord of the Claudes, a macOS menu bar app that watches the Claude Code \
        sessions one developer has open in Ghostty terminal tabs. The developer talks to you in a small chat \
        box above the list of sessions.

        Each message starts with a briefing in <briefing> tags: every open session by group (a Ghostty window) \
        and tab number, with its title, directory and status, and a digest of its goal, its state and what it \
        is blocked on when there is one. The newest briefing is the truth; older ones are out of date. You have \
        no tools and cannot read transcripts, files or the web. Answer from the briefing and this conversation \
        only, and say so when they do not tell you.

        How to answer:
        - Briefly: a sentence or two, or a short list. Plain text, UK English.
        - Name a session as a link: its title, then its group and tab number, like \
        [Fix flaky checkout test](session:Shop/2). A session with no tab number: [Its title](session:Other).
        - "What needs me" means the sessions waiting for the developer: say what each is waiting for, longest wait first.

        Proposing a prompt for a session:
        When the developer wants something said to a session, or writes what is plainly a prompt for one \
        session, propose it: one short sentence saying what you propose, then this block at the very end:

        ```lotc
        {"action": "send", "targets": [{"group": "Shop", "tab": 2, "title": "Fix flaky checkout test"}], "prompt": "rebase on main and run the tests again"}
        ```

        - "prompt" is the exact text to type into the session, addressed to it, in the developer's words \
        where you can. Add nothing of your own.
        - More than one target only when the developer asks for several sessions.
        - When no open session fits and the work needs a new one, propose a new session in the directory \
        the work belongs in, taken from the briefing:
        ```lotc
        {"action": "new", "group": "Shop", "cwd": "~/Projects/shop-api", "prompt": "..."}
        ```
        - When two or more sessions could be meant, ask which:
        ```lotc
        {"action": "choose", "question": "Which checkout session?", "candidates": [{"group": "Shop", "tab": 2, "title": "..."}, {"group": "Shop", "tab": 4, "title": "..."}], "prompt": "..."}
        ```
        - At most one block per reply, and only when proposing. Nothing is sent until the developer confirms \
        it in the panel, so never say that you have sent anything.
        """

    /// The developer's words, after the briefing and anything done since the last answer.
    static func message(_ text: String, briefing: String, since notes: [String], at date: Date = Date()) -> String {
        var parts = ["<briefing at=\"\(date.formatted(date: .omitted, time: .shortened))\">\n\(briefing)\n</briefing>"]
        if !notes.isEmpty {
            parts.append("<since-your-last-answer>\n" + notes.map { "- " + $0 }.joined(separator: "\n") + "\n</since-your-last-answer>")
        }
        parts.append(text)
        return parts.joined(separator: "\n\n")
    }
}

/// What the overseer needs from the app: the briefing, where sessions are, and the two ways to act.
/// Store is the real one.
@MainActor
protocol OverseerHost: AnyObject {
    func digestBriefing() -> String
    var overseerPlaces: [SessionPlace] { get }
    /// Types a prompt into a session's tab. False when its tab cannot be found.
    func send(_ text: String, toSession sessionId: String) async -> Bool
    /// Opens a tab in the window (the front one when it has gone) and starts Claude Code with the prompt.
    func startSession(prompt: String, cwd: String, windowId: String?) async -> Ghostty.NewTab?
}

extension Store: OverseerHost {
    /// Every running session, in the panel's groups and tab order, then those under "Other".
    var overseerPlaces: [SessionPlace] {
        var places = groups.flatMap { group in
            group.rows.map { SessionPlace(rowId: $0.id, group: group.name, windowId: group.id, tab: $0.tab, title: $0.title, cwd: $0.cwd) }
        }
        let placed = Set(places.map(\.rowId))
        places += rows.filter { $0.isLive && !placed.contains($0.id) }.map {
            SessionPlace(rowId: $0.id, group: "Other", windowId: nil, tab: nil, title: $0.title, cwd: $0.cwd)
        }
        return places
    }

    func startSession(prompt: String, cwd: String, windowId: String?) async -> Ghostty.NewTab? {
        await Task.detached { Ghostty.startClaude(prompt: prompt, cwd: cwd, inWindow: windowId) }.value
    }
}

/// The chat with the overseer. Lives as long as the app, so a half-written message or a pending
/// proposal survives the panel closing; the conversation itself survives restarts in overseer.json.
@MainActor
final class OverseerChat: ObservableObject {
    static let shared = OverseerChat(runner: ClaudeCLI(), file: OverseerFiles.conversation, settingsFile: OverseerFiles.settings)

    @Published private(set) var conversation: OverseerConversation
    @Published var draft = ""
    /// The answer so far while one is coming; nil when not asking.
    @Published private(set) var streaming: String?
    /// What the overseer proposes to do, waiting for the user's Send or Cancel.
    @Published var card: RoutingCard?
    /// "What needs me" is showing in place of the conversation.
    @Published var showingNeeds = false

    var isAsking: Bool { streaming != nil }

    private let runner: OverseerRunning
    private let file: URL?
    private let settingsFile: URL?
    /// What happened since the last answer, told to the overseer with the next message.
    private var unsaid: [String] = []
    private var asking: Task<Void, Never>?
    /// Bumped by "New chat", so a question cancelled by it leaves no trace in the new conversation.
    private var generation = 0

    init(runner: OverseerRunning, file: URL?, settingsFile: URL?) {
        self.runner = runner
        self.file = file
        self.settingsFile = settingsFile
        conversation = file.map(OverseerConversation.load(from:)) ?? OverseerConversation()
    }

    /// Made-up chat for the screenshots: reads and writes nothing and never runs Claude Code.
    init(demo messages: [OverseerMessage], card: RoutingCard? = nil) {
        runner = DemoRunner()
        file = nil
        settingsFile = nil
        conversation = OverseerConversation(sessionId: nil, messages: messages)
        self.card = card
    }

    /// Asks the overseer what is in the draft. A new question drops any proposal still on screen.
    func submit(to host: OverseerHost) {
        guard let text = draft.trimmedNonEmpty, !isAsking else { return }
        draft = ""
        showingNeeds = false
        if card != nil { cancelCard() }
        append(.user, text)
        let message = OverseerPrompt.message(text, briefing: host.digestBriefing(), since: unsaid)
        unsaid = []
        streaming = ""
        let current = generation
        asking = Task { await ask(message, host: host, generation: current) }
    }

    /// Waits for the answer to the question in flight. For tests.
    func settle() async { await asking?.value }

    func stop() { asking?.cancel() }

    /// Forgets the conversation here and starts a new one with Claude Code next time.
    func newChat() {
        asking?.cancel()
        asking = nil
        generation += 1
        streaming = nil
        card = nil
        unsaid = []
        conversation = OverseerConversation()
        save()
    }

    private func ask(_ message: String, host: OverseerHost, generation current: Int) async {
        let settings = settingsFile.map(OverseerSettings.load(from:)) ?? OverseerSettings()
        do {
            let reply: String
            do {
                reply = try await turn(message, settings: settings, sessionId: conversation.sessionId)
            } catch OverseerFailure.conversationGone {
                append(.note, "The earlier conversation had gone from Claude Code, so this starts a new one.")
                reply = try await turn(message, settings: settings, sessionId: nil)
            }
            let answer = OverseerAnswer.parse(reply)
            append(.overseer, answer.text.isEmpty && answer.proposal != nil ? "Here is what I would send." : answer.text)
            if answer.unreadableProposal { append(.note, "It proposed something the app could not read, so nothing is offered to send.") }
            if let proposal = answer.proposal { offer(RoutingCard.make(proposal, places: host.overseerPlaces)) }
        } catch is CancellationError {
            if generation == current { append(.note, "Stopped.") }
        } catch OverseerFailure.noClaude {
            append(.note, "Could not find Claude Code. Install it, or put the path of `claude` in overseer-settings.json as \"claude\".")
        } catch let OverseerFailure.failed(why) {
            append(.note, "The overseer could not answer: \(why)")
        } catch {
            append(.note, "The overseer could not answer: \(error.localizedDescription)")
        }
        guard generation == current else { return }
        streaming = nil
        asking = nil
    }

    /// One `claude -p`: resumes the conversation, or starts it under a fresh id. The id is kept once it has answered.
    private func turn(_ message: String, settings: OverseerSettings, sessionId: String?) async throws -> String {
        let id = sessionId ?? UUID().uuidString.lowercased()
        let request = OverseerRequest(message: message, systemPrompt: OverseerPrompt.system, sessionId: id,
                                      resume: sessionId != nil, settings: settings)
        var answer: String?
        for try await event in runner.run(request) {
            try Task.checkCancellation()
            switch event {
            case .partial(let text): streaming = OverseerAnswer.visibleWhileStreaming(text)
            case .answer(let text): answer = text
            }
        }
        try Task.checkCancellation()
        guard let answer else { throw OverseerFailure.failed("Claude Code gave no answer.") }
        conversation.sessionId = id
        return answer
    }

    // MARK: The confirm gate

    private func offer(_ card: RoutingCard) {
        self.card = card
        AccessibilityNotification.Announcement(card.headline + ". Return sends, Escape cancels.").post()
    }

    /// The only way anything the overseer proposes reaches a session: the user's Send on its card.
    /// From the keyboard it waits until the card has been on screen a moment, so a Return already on
    /// its way cannot send what nobody has read.
    func confirm(using host: OverseerHost, fromKeyboard: Bool = false) async {
        guard let card, card.canSend, !card.sending, !fromKeyboard || card.isArmed,
              let prompt = card.prompt.trimmedNonEmpty
        else { return }
        self.card?.sending = true
        switch card.kind {
        case .send(let places, _):
            var reached: [SessionPlace] = []
            var missed: [SessionPlace] = []
            for place in places {
                if await host.send(prompt, toSession: place.rowId) { reached.append(place) } else { missed.append(place) }
            }
            if !reached.isEmpty {
                append(.note, "Sent to \(Self.list(reached)).")
                unsaid.append("The developer sent this to \(Self.list(reached)): \(prompt)")
            }
            if !missed.isEmpty {
                append(.note, "Could not type into \(Self.list(missed)): its tab has gone or been renamed. Nothing was sent there.")
            }
        case .newSession(let cwd, let group, let windowId):
            switch await host.startSession(prompt: prompt, cwd: cwd, windowId: windowId) {
            case .inItsWindow?: append(.note, "Started a new session in \(group ?? "its window").")
            case .inFrontWindow?: append(.note, "Started a new session in the front window: \(group.map { "the \($0) window" } ?? "its window") has gone.")
            case .inNewWindow?: append(.note, "Started a new session in a new window.")
            case nil: append(.note, "Could not open a tab in Ghostty. Nothing was started.")
            }
            unsaid.append("The developer started a new session in \(cwd) with: \(prompt)")
        case .choose:
            break
        }
        if self.card?.id == card.id { self.card = nil }
    }

    func cancelCard() {
        guard card != nil else { return }
        card = nil
        append(.note, "Not sent.")
        unsaid.append("The developer cancelled your last proposal.")
    }

    /// Turns a "which one?" card into one that sends to the session picked.
    func choose(_ place: SessionPlace) {
        guard let card, case .choose = card.kind else { return }
        self.card = RoutingCard(kind: .send([place], missing: []), prompt: card.prompt)
    }

    /// A proposal waiting when the panel opens again must be read again before Return sends it.
    func panelOpened() { card?.shownAt = Date() }

    private func append(_ role: OverseerMessage.Role, _ text: String) {
        conversation.append(OverseerMessage(role: role, text: text))
        if role != .user { AccessibilityNotification.Announcement(text).post() }
        save()
    }

    private func save() { if let file { conversation.save(to: file) } }

    private static func list(_ places: [SessionPlace]) -> String {
        places.map { "\($0.spot) (\($0.title))" }.formatted(.list(type: .and))
    }
}

/// Never asked: the screenshots' chat only shows what it was given.
private struct DemoRunner: OverseerRunning {
    func run(_ request: OverseerRequest) -> AsyncThrowingStream<OverseerEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
}
