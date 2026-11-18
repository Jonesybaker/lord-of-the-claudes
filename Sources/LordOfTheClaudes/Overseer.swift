import CryptoKit
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
    /// Images pasted or dropped into the window, named by content hash.
    static let attachments = directory.appendingPathComponent("attachments")

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
    /// Images the user sent with it. Nil in files from before images, and on every other message.
    var attachments: [AttachedImage]?
    /// About a private session, answered by the app: shown here, never carried to the overseer. Nil on every other message.
    var isPrivate: Bool?

    var images: [AttachedImage] { attachments ?? [] }
}

/// The chat as kept in overseer.json: the last `cap` messages and Claude Code's id for the conversation.
struct OverseerConversation: Codable, Equatable {
    static let cap = 60

    /// Nil until the first answer, and again after "New chat".
    var sessionId: String?
    var messages: [OverseerMessage] = []
    /// `OverseerPrompt.fingerprint` of the instructions Claude Code recorded for `sessionId`. Nil in files from before it was kept.
    var instructions: String?

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
        You are the overseer in Lord of the Claudes, a macOS app that watches the Claude Code sessions one \
        developer has open in Ghostty terminal tabs. The developer talks to you in the app's main window, \
        beside the list of sessions.

        Each message starts with a briefing in <briefing> tags: every open session by group (a Ghostty window) \
        and tab number, with its title, directory, topic and status, and a digest of its goal, its state and \
        what it is blocked on when there is one. A topic gathers sessions on one subject across windows; use \
        it when the developer asks about a subject. The newest briefing is the truth; older ones are out of date. You have \
        no tools and cannot read transcripts, files or the web. Answer from the briefing and this conversation \
        only, and say so when they do not tell you.

        Some sessions are private. The briefing says how many are open and nothing else about them: not their \
        titles, directories or tabs. When the developer asks for a session the briefing does not show, say it may \
        be one of the private ones and that they can pick it in the sidebar, and propose nothing. Never guess \
        which session a private one is.

        How to answer:
        - Briefly: a sentence or two, or a short list. Plain text, UK English.
        - Name a session as a link: its title, then its group and tab number, like \
        [Fix flaky checkout test](session:Shop/2). A session with no tab number: [Its title](session:Other).
        - "What needs me" means the sessions waiting for the developer: say what each is waiting for, longest wait first.

        Which session is meant:
        - A send or goto block names one session only when the briefing clearly identifies it: its title, \
        topic, goal or state plainly fits what the developer said, and no other session does.
        - When it is a guess between two or more sessions, end with a choose block listing them, never a send \
        or goto for one of them.
        - When no session fits, say so and propose nothing, unless the work needs a new session.
        - Say that the app will ask which session only when your reply ends with a choose block.

        Proposing a prompt for a session:
        When the developer wants something said to a session, or writes what is plainly a prompt for one \
        session, propose it: one short sentence saying what you propose, then this block at the very end:

        ```lotc
        {"action": "send", "targets": [{"group": "Shop", "tab": 2, "title": "Fix flaky checkout test"}], "prompt": "rebase on main and run the tests again"}
        ```

        - "prompt" is the exact text to type into the session, addressed to it, in the developer's words \
        where you can. Add nothing of your own.
        - The developer may attach images, such as screenshots, which you see. A prompt proposed from a message \
        with images carries those images: the app adds them itself. Refer to them ("the attached screenshot") \
        rather than describing them, and never say they cannot be sent.
        - More than one target only when the developer asks for several sessions.
        - When no open session fits and the work needs a new one, propose a new session in the directory \
        the work belongs in, taken from the briefing:
        ```lotc
        {"action": "new", "group": "Shop", "cwd": "~/Projects/shop-api", "prompt": "..."}
        ```

        Taking the developer to a session:
        Most questions are answered from the briefing; answer those and propose nothing. Only when the answer \
        really is that the developer needs to look at a tab themselves (to review a diff or a page, to answer \
        something the digest does not show, or because they asked to be taken there), say why in one short \
        sentence and end with:
        ```lotc
        {"action": "goto", "target": {"group": "Shop", "tab": 2, "title": "Fix flaky checkout test"}}
        ```
        - The app shows a Go button and moves nothing until the developer presses it, so never say you have taken them there.

        Asking which session:
        When two or more sessions could be meant, by a prompt or by a request to go somewhere, end with:
        ```lotc
        {"action": "choose", "question": "Which checkout session?", "candidates": [{"group": "Shop", "tab": 2, "title": "..."}, {"group": "Shop", "tab": 4, "title": "..."}], "prompt": "..."}
        ```
        - "prompt" is what to send once the developer picks. Leave it out when they want to be taken there.
        - The app shows the candidates as buttons for the developer to pick from.

        At most one block per reply, and only when proposing. Nothing is sent until the developer confirms it in \
        the window, so never say that you have sent anything.
        """

    /// Changes whenever `system` does. A saved conversation whose instructions differ starts afresh, as
    /// Claude Code keeps the instructions a conversation began with (`--system-prompt-snapshot`).
    static let fingerprint: String = SHA256.hash(data: Data(system.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()

    /// How much of an earlier conversation goes with the first message of a fresh one.
    static let carriedMessages = 20
    static let carriedCharacters = 600

    /// The developer's words, after the briefing and anything done since the last answer. A fresh Claude Code
    /// conversation that follows an earlier one is given the end of it first, so the chat carries on, less any
    /// exchange about a private session. Images go beside this text, not in it.
    static func message(_ text: String, briefing: String, since notes: [String], earlier: [OverseerMessage] = [],
                        images: Int = 0, at date: Date = Date()) -> String {
        var parts: [String] = []
        let earlier = earlier.filter { $0.isPrivate != true }
        if !earlier.isEmpty { parts.append(carried(earlier)) }
        parts.append("<briefing at=\"\(date.formatted(date: .omitted, time: .shortened))\">\n\(briefing)\n</briefing>")
        if !notes.isEmpty {
            parts.append("<since-your-last-answer>\n" + notes.map { "- " + $0 }.joined(separator: "\n") + "\n</since-your-last-answer>")
        }
        parts.append(text.isEmpty && images > 0 ? "(\(imageCount(images)), with no words.)" : text)
        return parts.joined(separator: "\n\n")
    }

    static func imageCount(_ count: Int) -> String { count == 1 ? "An image" : "\(count) images" }

    private static func carried(_ messages: [OverseerMessage]) -> String {
        let lines = messages.suffix(carriedMessages).map { message in
            let who = switch message.role {
            case .user: "Developer"
            case .overseer: "You"
            case .note: "App"
            }
            let text = message.text.count > carriedCharacters ? message.text.prefix(carriedCharacters) + "…" : Substring(message.text)
            let images = message.images.isEmpty ? "" : " [\(imageCount(message.images.count).lowercased()) attached]"
            return "\(who): \(text)\(images)"
        }
        return (["<earlier-conversation>",
                 "Your conversation with the developer so far, carried over from an earlier Claude Code session. "
                     + "It is context only: the briefing below is newer."]
                + lines + ["</earlier-conversation>"]).joined(separator: "\n")
    }
}

/// What the overseer needs from the app: the briefing, where sessions are, and the two ways to act.
/// Store is the real one.
@MainActor
protocol OverseerHost: AnyObject {
    func digestBriefing() -> String
    var overseerPlaces: [SessionPlace] { get }
    /// Types a prompt into a session's tab, with the paths of its images. False when its tab cannot be found.
    func send(_ text: String, images: [AttachedImage], toSession sessionId: String) async -> Bool
    /// Opens a tab in the window (the front one when it has gone) and starts Claude Code with the prompt and images.
    func startSession(prompt: String, images: [AttachedImage], cwd: String, windowId: String?) async -> Ghostty.NewTab?
    /// Brings a session's tab to the front. False when its tab cannot be found.
    func goTo(session sessionId: String) -> Bool
}

extension Store: OverseerHost {
    /// Every running session, in window and tab order, then those under "Other". Private ones included, marked.
    var overseerPlaces: [SessionPlace] {
        var places = groups.flatMap { group in
            group.rows.map {
                SessionPlace(rowId: $0.id, group: group.name, windowId: group.id, tab: $0.tab, title: $0.title, cwd: $0.cwd,
                             isPrivate: $0.isPrivate)
            }
        }
        let placed = Set(places.map(\.rowId))
        places += rows.filter { $0.isLive && !placed.contains($0.id) }.map {
            SessionPlace(rowId: $0.id, group: "Other", windowId: nil, tab: nil, title: $0.title, cwd: $0.cwd, isPrivate: $0.isPrivate)
        }
        return places
    }

    func startSession(prompt: String, images: [AttachedImage], cwd: String, windowId: String?) async -> Ghostty.NewTab? {
        let text = TypedPrompt.text(prompt, images: images)
        // A new session reads the images with its Read tool, which asks first outside its own directories.
        let readable = images.isEmpty ? nil : OverseerFiles.attachments.path
        return await Task.detached { Ghostty.startClaude(prompt: text, cwd: cwd, inWindow: windowId, alsoReading: readable) }.value
    }
}

/// The chat with the overseer. Lives as long as the app, so a half-written message or a pending
/// proposal survives the window hiding; the conversation itself survives restarts in overseer.json.
@MainActor
final class OverseerChat: ObservableObject {
    static let shared = OverseerChat(runner: ClaudeCLI(), file: OverseerFiles.conversation, settingsFile: OverseerFiles.settings,
                                     attachments: OverseerFiles.attachments)

    @Published private(set) var conversation: OverseerConversation
    @Published var draft = ""
    /// Images pasted or dropped into the composer, to go with the draft.
    @Published var draftImages: [AttachedImage] = []
    /// The answer so far while one is coming; nil when not asking.
    @Published private(set) var streaming: String?
    /// What the overseer proposes to do, waiting for the user's Send or Cancel.
    @Published var card: RoutingCard?
    /// "What needs me" is showing in place of the conversation.
    @Published var showingNeeds = false

    var isAsking: Bool { streaming != nil }
    var hasDraft: Bool { draft.trimmedNonEmpty != nil || !draftImages.isEmpty }

    private let runner: OverseerRunning
    private let file: URL?
    private let settingsFile: URL?
    /// Where images are kept, for the clean-up. Nil cleans nothing up.
    let attachments: URL?
    /// What happened since the last answer, told to the overseer with the next message.
    private var unsaid: [String] = []
    private var asking: Task<Void, Never>?
    /// Bumped by "New chat", so a question cancelled by it leaves no trace in the new conversation.
    private var generation = 0

    init(runner: OverseerRunning, file: URL?, settingsFile: URL?, attachments: URL? = nil) {
        self.runner = runner
        self.file = file
        self.settingsFile = settingsFile
        self.attachments = attachments
        conversation = file.map(OverseerConversation.load(from:)) ?? OverseerConversation()
    }

    /// Made-up chat for the screenshots: reads and writes nothing and never runs Claude Code.
    init(demo messages: [OverseerMessage], card: RoutingCard? = nil) {
        runner = DemoRunner()
        file = nil
        settingsFile = nil
        attachments = nil
        conversation = OverseerConversation(sessionId: nil, messages: messages)
        self.card = card
    }

    /// Asks the overseer what is in the draft, its images with it. A new question drops any proposal still on screen.
    func submit(to host: OverseerHost) {
        guard hasDraft, !isAsking else { return }
        let text = draft.trimmedNonEmpty ?? ""
        let images = draftImages
        draft = ""
        draftImages = []
        showingNeeds = false
        if card != nil { cancelCard() }
        if let route = PrivateRoute.find(text, in: host.overseerPlaces) {
            answerHere(route, text: text, images: images)
            return
        }
        let earlier = conversation.messages
        // Claude Code would keep the old instructions on resume, so changed ones need a fresh conversation.
        let outdated = conversation.sessionId != nil && conversation.instructions != OverseerPrompt.fingerprint
        if outdated { append(.note, "The overseer has new instructions, so it starts a fresh conversation with this chat's recent messages.") }
        append(.user, text, images: images)
        let turn = Turn(text: text, images: images, briefing: host.digestBriefing(), since: unsaid, earlier: earlier,
                        resuming: outdated ? nil : conversation.sessionId)
        unsaid = []
        streaming = ""
        let current = generation
        asking = Task { await ask(turn, host: host, generation: current) }
    }

    /// One question as asked: the words, what went with them, and the conversation to carry on.
    private struct Turn {
        let text: String
        let images: [AttachedImage]
        let briefing: String
        let since: [String]
        /// The chat before this question, given to a fresh Claude Code conversation.
        let earlier: [OverseerMessage]
        /// Nil starts a fresh Claude Code conversation.
        let resuming: String?

        func message(fresh: Bool) -> String {
            OverseerPrompt.message(text, briefing: briefing, since: since, earlier: fresh ? earlier : [], images: images.count)
        }
    }

    /// A message naming a private session, answered without the overseer: the words stay on screen and out of
    /// everything it is told.
    private func answerHere(_ route: PrivateRoute, text: String, images: [AttachedImage]) {
        append(.user, text, images: images, isPrivate: true)
        append(.note, route.answer, isPrivate: true)
        var card = route.card
        if card.hasPrompt { card.images = images }
        offer(card)
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

    private func ask(_ question: Turn, host: OverseerHost, generation current: Int) async {
        let settings = settingsFile.map(OverseerSettings.load(from:)) ?? OverseerSettings()
        do {
            let reply: String
            do {
                reply = try await turn(question.message(fresh: question.resuming == nil), images: question.images,
                                       settings: settings, sessionId: question.resuming)
            } catch OverseerFailure.conversationGone {
                append(.note, "The earlier conversation had gone from Claude Code, so this starts a new one.")
                reply = try await turn(question.message(fresh: true), images: question.images, settings: settings, sessionId: nil)
            }
            let answer = OverseerAnswer.parse(reply)
            // It is never told of private sessions, so nothing it proposes may land on one.
            let shared = host.overseerPlaces.filter { !$0.isPrivate }
            let card = answer.proposal.map { RoutingCard.make($0.checked(against: answer.text, places: shared), places: shared) }
            let text = card?.asksWhich == true ? answer.text : AnswerText.withoutPromisedChoice(answer.text)
            append(.overseer, text.isEmpty && card != nil ? "Here is what I would send." : text)
            if answer.unreadableProposal { append(.note, "It proposed something the app could not read, so nothing is offered to send.") }
            if var card {
                // The images asked about go with the prompt, listed on the card before anything is sent.
                if card.hasPrompt { card.images = question.images }
                offer(card)
            }
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
    private func turn(_ message: String, images: [AttachedImage], settings: OverseerSettings, sessionId: String?) async throws -> String {
        let id = sessionId ?? UUID().uuidString.lowercased()
        var request = OverseerRequest(message: message, systemPrompt: OverseerPrompt.system, sessionId: id,
                                      resume: sessionId != nil, settings: settings)
        request.images = images
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
        conversation.instructions = OverseerPrompt.fingerprint
        return answer
    }

    // MARK: The confirm gate

    private func offer(_ card: RoutingCard) {
        self.card = card
        let keys = card.isGoTo ? "Return goes there, Escape cancels." : "Return sends, Escape cancels."
        AccessibilityNotification.Announcement(card.headline + ". " + keys).post()
    }

    /// The only way anything the overseer proposes reaches a session or moves a tab: the user's Send, Start
    /// or Go on its card. From the keyboard it waits until the card has been on screen a moment, so a Return
    /// already on its way cannot act on what nobody has read.
    func confirm(using host: OverseerHost, fromKeyboard: Bool = false) async {
        guard let card, card.canSend, !card.sending, !fromKeyboard || card.isArmed else { return }
        let prompt = card.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = card.images
        let withImages = images.isEmpty ? "" : ", with \(OverseerPrompt.imageCount(images.count).lowercased())"
        // A private session's card was the app's: its outcome shows here and is never told to the overseer.
        let note = { (text: String) in self.append(.note, text, isPrivate: card.isPrivate) }
        let tell = { (text: String) in if !card.isPrivate { self.unsaid.append(text) } }
        self.card?.sending = true
        switch card.kind {
        case .send(let places, _):
            var reached: [SessionPlace] = []
            var missed: [SessionPlace] = []
            for place in places {
                if await host.send(prompt, images: images, toSession: place.rowId) { reached.append(place) } else { missed.append(place) }
            }
            if !reached.isEmpty {
                note("Sent to \(Self.list(reached))\(withImages).")
                tell("The developer sent this to \(Self.list(reached))\(withImages): \(prompt)")
            }
            if !missed.isEmpty {
                note("Could not type into \(Self.list(missed)): its tab has gone or been renamed. Nothing was sent there.")
            }
        case .newSession(let cwd, let group, let windowId):
            switch await host.startSession(prompt: prompt, images: images, cwd: cwd, windowId: windowId) {
            case .inItsWindow?: note("Started a new session in \(group ?? "its window")\(withImages).")
            case .inFrontWindow?: note("Started a new session in the front window\(withImages): \(group.map { "the \($0) window" } ?? "its window") has gone.")
            case .inNewWindow?: note("Started a new session in a new window\(withImages).")
            case nil: note("Could not open a tab in Ghostty. Nothing was started.")
            }
            tell("The developer started a new session in \(cwd)\(withImages) with: \(prompt)")
        case .goTo(let places, _):
            guard let place = places.first else { break }
            if host.goTo(session: place.rowId) {
                note("Went to \(Self.list([place])).")
                tell("The developer went to \(Self.list([place])) to look for themselves.")
            } else {
                note("Could not find the tab of \(Self.list([place])). It may have closed.")
            }
        case .choose:
            break
        }
        if self.card?.id == card.id { self.card = nil }
    }

    func cancelCard() {
        guard let card else { return }
        self.card = nil
        append(.note, card.isGoTo ? "Stayed here." : "Not sent.", isPrivate: card.isPrivate)
        if !card.isPrivate { unsaid.append("The developer cancelled your last proposal.") }
    }

    /// Narrows a "which one?" card to the session picked, still waiting for Send or Go.
    func choose(_ place: SessionPlace) {
        guard let card else { return }
        var picked: RoutingCard
        switch card.kind {
        case .choose: picked = RoutingCard(kind: .send([place], missing: []), prompt: card.prompt, images: card.images)
        case .goTo(let places, _) where places.count > 1: picked = RoutingCard(kind: .goTo([place], missing: []), prompt: "")
        default: return
        }
        picked.isPrivate = card.isPrivate
        self.card = picked
    }

    /// A proposal waiting when the window shows again must be read again before Return acts on it.
    func windowShown() { card?.shownAt = Date() }

    private func append(_ role: OverseerMessage.Role, _ text: String, images: [AttachedImage] = [], isPrivate: Bool = false) {
        conversation.append(OverseerMessage(role: role, text: text, attachments: images.isEmpty ? nil : images,
                                            isPrivate: isPrivate ? true : nil))
        if role != .user { AccessibilityNotification.Announcement(text).post() }
        save()
    }

    // MARK: Images

    /// Every image something here still refers to: the saved messages, the draft and the card.
    var imagesInUse: Set<String> {
        Set((conversation.messages.flatMap(\.images) + draftImages + (card?.images ?? [])).map(\.path))
    }

    /// Removes the week-old images nothing refers to, off the main thread. `keeping` adds images held elsewhere.
    func sweepAttachments(keeping more: [AttachedImage] = []) {
        guard let attachments else { return }
        let keeping = imagesInUse.union(more.map(\.path))
        DispatchQueue.global(qos: .utility).async { AttachmentSweep.sweep(attachments, keeping: keeping) }
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
