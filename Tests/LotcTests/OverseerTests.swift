import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import LordOfTheClaudes
@testable import LotcKit

/// Two made-up Ghostty windows: "United" and "Shop".
private let places = [
    SessionPlace(rowId: "a", group: "United", windowId: "w1", tab: 1, title: "Plan the treble", cwd: "/p/united"),
    SessionPlace(rowId: "b", group: "United", windowId: "w1", tab: 2, title: "Scout Rashford", cwd: "/p/united"),
    SessionPlace(rowId: "c", group: "United", windowId: "w1", tab: 3, title: "Scout Fernandes", cwd: "/p/united"),
    SessionPlace(rowId: "d", group: "Shop", windowId: "w2", tab: 1, title: "Fix flaky checkout test", cwd: "/p/shop"),
    SessionPlace(rowId: "e", group: "Other", windowId: nil, tab: nil, title: "Kit launch copy", cwd: "/p/kit"),
]

struct OverseerAnswerTests {
    @Test func aPlainAnswerOffersNothing() {
        let answer = OverseerAnswer.parse("  [Plan the treble](session:United/1) is waiting for you.\n")
        #expect(answer == OverseerAnswer(text: "[Plan the treble](session:United/1) is waiting for you.", proposal: nil, unreadableProposal: false))
    }

    @Test func readsASendProposalAndKeepsItOutOfTheText() {
        let answer = OverseerAnswer.parse("""
            I would send this to the checkout session.

            ```lotc
            {"action": "send", "targets": [{"group": "Shop", "tab": 1, "title": "Fix flaky checkout test"}], "prompt": "rebase on main"}
            ```
            """)
        #expect(answer.text == "I would send this to the checkout session.")
        #expect(answer.proposal == .send(targets: [ProposedTarget(group: "Shop", tab: 1, title: "Fix flaky checkout test")], prompt: "rebase on main"))
        #expect(!answer.unreadableProposal)
    }

    @Test func readsANewSessionAndAChoiceWithTabsWrittenAsText() {
        let new = OverseerAnswer.parse("""
            Nothing open fits; a new one in the shop.
            ```lotc
            {"action":"new","group":"Shop","cwd":"~/Projects/shop","prompt":"add a size guide"}
            ```
            """)
        #expect(new.proposal == .newSession(group: "Shop", cwd: "~/Projects/shop", prompt: "add a size guide"))

        let choose = OverseerAnswer.parse("""
            Which scout?
            ```json
            {"action":"choose","question":"Which scout?","candidates":[{"group":"United","tab":"tab 2"},{"group":"United","tab":"3"}],"prompt":"write it up"}
            ```
            """)
        #expect(choose.proposal == .choose(question: "Which scout?",
                                           candidates: [ProposedTarget(group: "United", tab: 2), ProposedTarget(group: "United", tab: 3)],
                                           prompt: "write it up"))
    }

    @Test func readsABareBlockAtTheEnd() {
        let answer = OverseerAnswer.parse(#"Sending it. {"action":"send","targets":[{"title":"Scout Rashford"}],"prompt":"stop"}"#)
        #expect(answer.text == "Sending it.")
        #expect(answer.proposal == .send(targets: [ProposedTarget(title: "Scout Rashford")], prompt: "stop"))
    }

    @Test(arguments: [
        "```lotc\n{\"action\": \"send\", \"targets\": [\n```",  // cut off
        "```lotc\n{\"action\": \"delete everything\", \"prompt\": \"x\"}\n```",  // no such action
        "```lotc\n{\"action\": \"send\", \"targets\": [], \"prompt\": \"x\"}\n```",  // nobody to send to
        "```lotc\n{\"action\": \"send\", \"targets\": [{\"tab\": 1}], \"prompt\": \"  \"}\n```",  // nothing to send
        "```lotc\nnot json at all\n```",
    ])
    func junkOffersNothingAndNeverShows(_ block: String) {
        let answer = OverseerAnswer.parse("Here you go.\n" + block)
        #expect(answer.text == "Here you go.")
        #expect(answer.proposal == nil)
        #expect(answer.unreadableProposal)
    }

    @Test func otherCodeStaysInTheAnswer() {
        let text = "Run this:\n```\nswift build\n```"
        #expect(OverseerAnswer.parse(text) == OverseerAnswer(text: text, proposal: nil, unreadableProposal: false))
    }

    @Test(arguments: [
        ("I'll send it.\n\n```lotc\n{\"action\"", "I'll send it."),
        ("I'll send it.\n\n``", "I'll send it."),
        ("Two are waiting: [Plan", "Two are waiting: [Plan"),
    ])
    func hidesTheBlockWhileItStreams(partial: String, shown: String) {
        #expect(OverseerAnswer.visibleWhileStreaming(partial) == shown)
    }
}

struct TargetMatchTests {
    @Test func findsByGroupAndTab() {
        #expect(TargetMatch.find(ProposedTarget(group: "united", tab: 2, title: "Scout Rashford"), in: places) == .one(places[1]))
        #expect(TargetMatch.find(ProposedTarget(group: "Shop", tab: 1), in: places) == .one(places[3]))
    }

    @Test func aTabThatMovedIsFoundByTitle() {
        // Tab 1 closed and the rest moved up: tab 2 is now another session.
        #expect(TargetMatch.find(ProposedTarget(group: "United", tab: 1, title: "Scout Fernandes"), in: places) == .one(places[2]))
    }

    @Test func neverTakesATabWhoseTitleDisagrees() {
        #expect(TargetMatch.find(ProposedTarget(group: "United", tab: 2, title: "Sign Bellingham"), in: places) == .none)
    }

    @Test func findsByTitleAloneAndAcrossARenamedGroup() {
        #expect(TargetMatch.find(ProposedTarget(title: "kit launch copy"), in: places) == .one(places[4]))
        #expect(TargetMatch.find(ProposedTarget(group: "Old name", title: "Fix flaky checkout test"), in: places) == .one(places[3]))
        #expect(TargetMatch.find(ProposedTarget(title: "checkout"), in: places) == .one(places[3]))
    }

    @Test func aSharedPieceOfTitleIsAmbiguous() {
        #expect(TargetMatch.find(ProposedTarget(group: "United", title: "Scout"), in: places) == .several([places[1], places[2]]))
    }

    @Test func aGroupAloneMeansItsOnlySession() {
        #expect(TargetMatch.find(ProposedTarget(group: "Shop"), in: places) == .one(places[3]))
        #expect(TargetMatch.find(ProposedTarget(group: "United"), in: places) == .none)
        #expect(TargetMatch.find(ProposedTarget(group: "Nowhere"), in: places) == .none)
    }

    @Test func readsLinkReferences() {
        #expect(ProposedTarget(reference: "Shop 2/3", label: "x") == ProposedTarget(group: "Shop 2", tab: 3, title: "x"))
        #expect(ProposedTarget(reference: "United, tab 2", label: "x") == ProposedTarget(group: "United", tab: 2, title: "x"))
        #expect(ProposedTarget(reference: "Other", label: "x") == ProposedTarget(group: "Other", title: "x"))
    }

    @Test func linksTheSessionsItCanFind() {
        let text = "[Scout Rashford](session:United/2) is done; [Sign Bellingham](session:United/9) is not open."
        #expect(AnswerText.linked(text, places: places)
                == "[Scout Rashford](lotc-session://b) is done; Sign Bellingham is not open.")
        #expect(AnswerText.sessionId(in: URL(string: "lotc-session://b")!) == "b")
        #expect(AnswerText.sessionId(in: URL(string: "https://b")!) == nil)
    }
}

struct RoutingCardTests {
    @Test func aSendGoesToTheSessionsFound() {
        let card = RoutingCard.make(.send(targets: [ProposedTarget(group: "Shop", tab: 1), ProposedTarget(title: "Sign Bellingham")],
                                          prompt: "go"), places: places)
        #expect(card.kind == .send([places[3]], missing: ["\"Sign Bellingham\""]))
        #expect(card.canSend)
        #expect(card.headline == "Send to Shop, tab 1, Fix flaky checkout test")
    }

    @Test func anAmbiguousTargetAsksWhich() {
        let card = RoutingCard.make(.send(targets: [ProposedTarget(title: "Scout")], prompt: "go"), places: places)
        #expect(card.kind == .choose(question: "Which session?", candidates: [places[1], places[2]]))
        #expect(!card.canSend)
    }

    @Test func aChoiceOfOneIsASend() {
        let card = RoutingCard.make(.choose(question: nil, candidates: [ProposedTarget(title: "Plan the treble")], prompt: "go"), places: places)
        #expect(card.kind == .send([places[0]], missing: []))
    }

    @Test func aNewSessionGoesToItsGroupsWindow() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let card = RoutingCard.make(.newSession(group: "shop", cwd: "~", prompt: "start"), places: places)
        #expect(card.kind == .newSession(cwd: home, group: "shop", windowId: "w2"))
        #expect(card.canSend)
        let nowhere = RoutingCard.make(.newSession(group: "Nowhere", cwd: "/no/such/place", prompt: "start"), places: places)
        #expect(nowhere.kind == .newSession(cwd: "/no/such/place", group: "Nowhere", windowId: nil))
        #expect(!nowhere.canSend)
    }
}

/// Plays back canned replies, as `claude -p` would stream them.
private final class FakeRunner: OverseerRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<String, OverseerFailure>]
    private(set) var requests: [OverseerRequest] = []

    init(_ replies: [Result<String, OverseerFailure>]) { self.replies = replies }

    func run(_ request: OverseerRequest) -> AsyncThrowingStream<OverseerEvent, Error> {
        lock.lock()
        requests.append(request)
        let reply = replies.isEmpty ? .failure(.failed("no reply left")) : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            switch reply {
            case .success(let text):
                continuation.yield(.partial(String(text.prefix(text.count / 2))))
                continuation.yield(.answer(text))
                continuation.finish()
            case .failure(let failure):
                continuation.finish(throwing: failure)
            }
        }
    }
}

@MainActor
private final class FakeHost: OverseerHost {
    var overseerPlaces = places
    private(set) var sent: [(text: String, sessionId: String)] = []
    private(set) var started: [(prompt: String, cwd: String, windowId: String?)] = []

    func digestBriefing() -> String { "Group \"United\": ..." }

    func send(_ text: String, toSession sessionId: String) async -> Bool {
        sent.append((text, sessionId))
        return true
    }

    func startSession(prompt: String, cwd: String, windowId: String?) async -> Ghostty.NewTab? {
        started.append((prompt, cwd, windowId))
        return .inItsWindow
    }
}

private let sendToShop = """
    I would send this to the checkout session.
    ```lotc
    {"action": "send", "targets": [{"group": "Shop", "tab": 1, "title": "Fix flaky checkout test"}], "prompt": "rebase on main"}
    ```
    """

@MainActor
struct ConfirmGateTests {
    private func ask(_ chat: OverseerChat, _ host: FakeHost, _ text: String) async {
        chat.draft = text
        chat.submit(to: host)
        await chat.settle()
    }

    private func arm(_ chat: OverseerChat) { chat.card?.shownAt = .distantPast }

    @Test func aProposalSendsNothingUntilConfirmed() async throws {
        let host = FakeHost()
        let chat = OverseerChat(runner: FakeRunner([.success(sendToShop)]), file: nil, settingsFile: nil)
        await ask(chat, host, "tell the checkout one to rebase")
        #expect(host.sent.isEmpty)
        let card = try #require(chat.card)
        #expect(card.kind == .send([places[3]], missing: []))
        #expect(chat.conversation.messages.map(\.role) == [.user, .overseer])

        chat.card?.prompt = "rebase on main, then run the tests"  // edited before sending
        await chat.confirm(using: host)
        #expect(host.sent.map(\.text) == ["rebase on main, then run the tests"])
        #expect(host.sent.map(\.sessionId) == ["d"])
        #expect(chat.card == nil)
        #expect(chat.conversation.messages.last?.text == "Sent to Shop, tab 1 (Fix flaky checkout test).")
    }

    @Test func cancelSendsNothingAndTellsTheOverseerNextTime() async {
        let host = FakeHost()
        let runner = FakeRunner([.success(sendToShop), .success("Fine.")])
        let chat = OverseerChat(runner: runner, file: nil, settingsFile: nil)
        await ask(chat, host, "tell the checkout one to rebase")
        chat.cancelCard()
        await chat.confirm(using: host)
        #expect(host.sent.isEmpty)
        await ask(chat, host, "never mind")
        #expect(runner.requests.last?.message.contains("cancelled your last proposal") == true)
    }

    @Test func returnDoesNothingUntilTheCardHasBeenSeen() async {
        let host = FakeHost()
        let chat = OverseerChat(runner: FakeRunner([.success(sendToShop)]), file: nil, settingsFile: nil)
        await ask(chat, host, "tell the checkout one to rebase")
        await chat.confirm(using: host, fromKeyboard: true)
        #expect(host.sent.isEmpty)
        arm(chat)
        chat.panelOpened()  // reopening the panel shows it afresh
        await chat.confirm(using: host, fromKeyboard: true)
        #expect(host.sent.isEmpty)
        arm(chat)
        await chat.confirm(using: host, fromKeyboard: true)
        #expect(host.sent.count == 1)
    }

    @Test func aChoiceSendsOnlyOnceOneIsPicked() async {
        let host = FakeHost()
        let reply = """
            Which scout?
            ```lotc
            {"action":"choose","question":"Which scout?","candidates":[{"group":"United","tab":2},{"group":"United","tab":3}],"prompt":"write it up"}
            ```
            """
        let chat = OverseerChat(runner: FakeRunner([.success(reply)]), file: nil, settingsFile: nil)
        await ask(chat, host, "tell the scout to write it up")
        await chat.confirm(using: host)
        #expect(host.sent.isEmpty)
        chat.choose(places[2])
        await chat.confirm(using: host)
        #expect(host.sent.map(\.sessionId) == ["c"])
    }

    @Test func aNewSessionStartsOnlyWhenConfirmed() async {
        let host = FakeHost()
        let reply = "A new one.\n```lotc\n{\"action\":\"new\",\"group\":\"Shop\",\"cwd\":\"/\",\"prompt\":\"add a size guide\"}\n```"
        let chat = OverseerChat(runner: FakeRunner([.success(reply)]), file: nil, settingsFile: nil)
        await ask(chat, host, "start something for the size guide")
        #expect(host.started.isEmpty)
        await chat.confirm(using: host)
        #expect(host.started.map(\.prompt) == ["add a size guide"])
        #expect(host.started.map(\.windowId) == ["w2"])
        #expect(host.sent.isEmpty)
    }

    @Test func aPlainAnswerOrAFailureOffersNothing() async {
        let host = FakeHost()
        let chat = OverseerChat(runner: FakeRunner([.success("All quiet."), .failure(.noClaude)]), file: nil, settingsFile: nil)
        await ask(chat, host, "anything?")
        #expect(chat.card == nil)
        await ask(chat, host, "and now?")
        #expect(chat.card == nil)
        #expect(chat.conversation.messages.last?.role == .note)
        #expect(host.sent.isEmpty)
    }
}

@MainActor
struct OverseerConversationTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lotc-overseer-\(UUID().uuidString).json")
    }

    @Test func keepsOnlyTheLatestMessages() {
        var conversation = OverseerConversation()
        for n in 1...7 { conversation.append(OverseerMessage(role: .user, text: "\(n)"), cap: 5) }
        #expect(conversation.messages.map(\.text) == ["3", "4", "5", "6", "7"])
    }

    @Test func survivesARestartAndNewChatClearsIt() async {
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file) }
        let host = FakeHost()
        let runner = FakeRunner([.success("Two are waiting."), .success("Still two.")])
        let chat = OverseerChat(runner: runner, file: file, settingsFile: nil)
        chat.draft = "what needs me?"
        chat.submit(to: host)
        await chat.settle()

        let restarted = OverseerChat(runner: runner, file: file, settingsFile: nil)
        #expect(restarted.conversation == chat.conversation)
        #expect(restarted.conversation.messages.map(\.text) == ["what needs me?", "Two are waiting."])
        let first = runner.requests[0]
        #expect(!first.resume)

        restarted.draft = "and now?"
        restarted.submit(to: host)
        await restarted.settle()
        #expect(runner.requests[1].resume && runner.requests[1].sessionId == first.sessionId)

        restarted.newChat()
        #expect(OverseerChat(runner: runner, file: file, settingsFile: nil).conversation == OverseerConversation())
    }

    @Test func startsAgainWhenTheOldConversationHasGone() async {
        let host = FakeHost()
        let runner = FakeRunner([.success("Hello."), .failure(.conversationGone), .success("Hello again.")])
        let chat = OverseerChat(runner: runner, file: nil, settingsFile: nil)
        for text in ["hi", "hi again"] {
            chat.draft = text
            chat.submit(to: host)
            await chat.settle()
        }
        #expect(runner.requests.map(\.resume) == [false, true, false])
        #expect(runner.requests[2].sessionId != runner.requests[0].sessionId)
        #expect(chat.conversation.messages.last?.text == "Hello again.")
        #expect(chat.conversation.sessionId == runner.requests[2].sessionId)
    }

    @Test func settingsFallBackToTheirDefaults() throws {
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(OverseerSettings.load(from: file) == OverseerSettings())
        #expect(FileManager.default.fileExists(atPath: file.path))  // written for the user to find
        try Data(#"{"model": "opus", "effort": ""}"#.utf8).write(to: file)
        let settings = OverseerSettings.load(from: file)
        #expect(settings.model == "opus" && settings.effort == nil && settings.claude == nil)
    }
}

struct NeedsYouTests {
    private func row(_ id: String, status: String?, needsYou: Bool, stoppedMinutesAgo: Double,
                     blockedOn: String? = nil, prompt: String? = nil) -> Row {
        let stopped = Date().addingTimeInterval(-stoppedMinutesAgo * 60)
        return Row(id: id, title: "Session \(id)", cwd: "/p", status: status, statusSince: stopped, lastInteraction: stopped,
                   needsYou: needsYou, prompts: prompt.map { [(stopped, $0)] } ?? [], ticket: nil, windowId: "w", tab: 1,
                   digest: blockedOn.map { Digest(goal: "g", state: "s", blockedOn: $0, at: stopped) })
    }

    @Test func longestWaitFirstAcrossEveryWindow() {
        let rows = [
            row("recent", status: "idle", needsYou: true, stoppedMinutesAgo: 2),
            row("busy", status: "busy", needsYou: false, stoppedMinutesAgo: 90, blockedOn: "old question"),
            row("seen but blocked", status: "idle", needsYou: false, stoppedMinutesAgo: 30, blockedOn: "Which kit supplier?"),
            row("quiet", status: "idle", needsYou: false, stoppedMinutesAgo: 300),
            row("closed", status: nil, needsYou: false, stoppedMinutesAgo: 600, blockedOn: "x"),
            row("oldest", status: "idle", needsYou: true, stoppedMinutesAgo: 45, prompt: "price the away kit\nin pounds"),
        ]
        #expect(NeedsYou.ranked(rows).map(\.id) == ["oldest", "seen but blocked", "recent"])
        #expect(NeedsYou.reason(rows[2]) == "Which kit supplier?")
        #expect(NeedsYou.reason(rows[5]) == "Finished. You last asked: price the away kit")
    }
}

struct OverseerPlumbingTests {
    @Test func findsClaudeWhereverItLives() {
        let home = "/Users/fan"
        var askedLoginShell = 0
        func find(_ installed: Set<String>, path: String? = "/usr/bin:/bin", override: String? = nil, login: String? = nil) -> String? {
            ClaudeBinary.find(override: override, path: path, home: home,
                              loginPath: { askedLoginShell += 1; return login }, isExecutable: installed.contains)
        }
        #expect(find(["/opt/homebrew/bin/claude", "/Users/fan/.local/bin/claude"]) == "/Users/fan/.local/bin/claude")
        #expect(find(["/usr/bin/claude", "/Users/fan/.local/bin/claude"]) == "/usr/bin/claude")
        #expect(askedLoginShell == 0)
        #expect(find(["/Users/fan/.asdf/shims/claude"], login: "/Users/fan/.asdf/shims:/usr/bin") == "/Users/fan/.asdf/shims/claude")
        #expect(askedLoginShell == 1)
        #expect(find(["/elsewhere/claude", "/usr/bin/claude"], override: "/elsewhere/claude") == "/elsewhere/claude")
        #expect(find([]) == nil)
    }

    @Test func runsWithoutToolsHooksOrMemory() {
        var settings = OverseerSettings()
        settings.model = "opus"
        let first = ClaudeCLI.arguments(for: OverseerRequest(message: "m", systemPrompt: "s", sessionId: "id", resume: false, settings: settings))
        #expect(first.contains("--safe-mode"))
        #expect(first.firstIndex(of: "--tools").map { first[$0 + 1] } == "")
        #expect(first.firstIndex(of: "--model").map { first[$0 + 1] } == "opus")
        #expect(first.firstIndex(of: "--session-id").map { first[$0 + 1] } == "id" && !first.contains("--resume"))
        let later = ClaudeCLI.arguments(for: OverseerRequest(message: "m", systemPrompt: "s", sessionId: "id", resume: true, settings: settings))
        #expect(later.firstIndex(of: "--resume").map { later[$0 + 1] } == "id" && !later.contains("--session-id"))
    }

    @Test func readsTheStream() {
        #expect(StreamLine.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Two are"}}}"#)
                == .textDelta("Two are"))
        #expect(StreamLine.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}}"#)
                == .other)
        #expect(StreamLine.parse(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Done."}]}}"#)
                == .message("Done."))
        #expect(StreamLine.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"Done."}"#)
                == .result(text: "Done.", isError: false, errors: []))
        #expect(StreamLine.parse(#"{"type":"result","is_error":true,"errors":["No conversation found with session ID: x"]}"#)
                == .result(text: "", isError: true, errors: ["No conversation found with session ID: x"]))
        #expect(StreamLine.parse("not json") == .other)
    }

    @Test func quotesAPromptForTheShell() {
        #expect(Ghostty.shellQuoted("it's \"done\" $HOME") == #"'it'\''s "done" $HOME'"#)
    }

    @Test func theMessageCarriesTheBriefingAndWhatHappened() {
        let message = OverseerPrompt.message("what needs me?", briefing: "Group \"Shop\":", since: ["The developer sent x"])
        #expect(message.hasPrefix("<briefing at="))
        #expect(message.contains("Group \"Shop\":\n</briefing>"))
        #expect(message.contains("- The developer sent x"))
        #expect(message.hasSuffix("\n\nwhat needs me?"))
    }

    @Test func neverListsTheOverseersOwnSession() {
        #expect(OverseerFiles.isOverseer(cwd: OverseerFiles.workspace.path + "/"))
        #expect(!OverseerFiles.isOverseer(cwd: "/p/shop"))
    }
}

struct OverseerKeysTests {
    private func route(_ code: Int, _ characters: String = "", _ modifiers: NSEvent.ModifierFlags = [],
                       focus: PanelField?, empty: Bool = true) -> OverseerKeys.Route {
        OverseerKeys.route(keyCode: code, modifiers: modifiers, characters: characters, focus: focus, chatIsEmpty: empty)
    }

    @Test func theChatFieldSharesTheListsKeys() {
        #expect(route(kVK_DownArrow, focus: .overseer, empty: false) == .list)
        #expect(route(kVK_ANSI_R, "r", .command, focus: .overseer, empty: false) == .list)
        #expect(route(kVK_ANSI_3, "3", .command, focus: .overseer) == .list)
        #expect(route(kVK_ANSI_F, "f", .command, focus: .overseer) == .focusFilter)
        #expect(route(kVK_Return, focus: .overseer, empty: true) == .list)  // jumps to the session
        #expect(route(kVK_Return, focus: .overseer, empty: false) == .field)  // asks the overseer
        #expect(route(kVK_LeftArrow, focus: .overseer, empty: false) == .field)
        #expect(route(kVK_ANSI_A, "a", focus: .overseer) == .field)
    }

    @Test func onlyPlainReturnOnTheCardSends() {
        #expect(route(kVK_Return, focus: .proposal) == .confirmCard)
        #expect(route(kVK_Return, "\r", .shift, focus: .proposal) == .field)
        #expect(route(kVK_DownArrow, focus: .proposal) == .field)
        #expect(route(kVK_Return, focus: .reply(sessionId: "a")) == .field)
        #expect(route(kVK_Return, focus: .search) == .list)
    }
}
