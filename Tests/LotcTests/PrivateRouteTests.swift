import Foundation
import Testing
@testable import LordOfTheClaudes
@testable import LotcKit

/// Made-up sessions: two open to the overseer, three private.
private let sessions = [
    SessionPlace(rowId: "rashford", group: "United", windowId: "w1", tab: 1, title: "Scout Rashford", cwd: "/p/united"),
    SessionPlace(rowId: "contract", group: "United", windowId: "w1", tab: 2, title: "Scout Rashford contract",
                 cwd: "/p/private/contracts", isPrivate: true),
    SessionPlace(rowId: "checkout", group: "Shop", windowId: "w2", tab: 1, title: "Fix flaky checkout test", cwd: "/p/shop"),
    SessionPlace(rowId: "mortgage", group: "Other", windowId: nil, tab: nil, title: "Reconcile the mortgage statements",
                 cwd: "/p/private/mortgage", isPrivate: true),
    SessionPlace(rowId: "words", group: "Other", windowId: nil, tab: nil, title: "Go to the chat", cwd: "/p/private/x", isPrivate: true),
]
private let rashford = sessions[0], contract = sessions[1], mortgage = sessions[3]

struct PrivateRouteTests {
    private func route(_ message: String, in places: [SessionPlace] = sessions) -> PrivateRoute? {
        PrivateRoute.find(message, in: places)
    }

    @Test func matchesAllOfATitlesWordsOrTwoThirds() {
        #expect(route("let's go to the chat talking about reconcile mortgage") == .goTo(mortgage))
        #expect(route("take me to the mortgage statements one") == .goTo(mortgage))
        #expect(route("Reconcile the Mortgage Statements") == .goTo(mortgage))
        #expect(route("what is the reconcile mortgage one doing?") == .goTo(mortgage))
    }

    @Test func oneWordOfThreeOrNoneIsNoMatch() {
        #expect(route("take me to the mortgage one") == nil)
        #expect(route("what needs me?") == nil)
        #expect(route("take me to the kit launch") == nil)
        #expect(route("") == nil)
    }

    @Test func ordinaryWordsAloneNeverMatch() {
        #expect(TitleWords.distinctive("Go to the chat").isEmpty)
        #expect(route("go to the chat") == nil)
        #expect(route("take me to the one we were talking about") == nil)
        #expect(route("let's go there now please") == nil)
    }

    @Test func twoPrivateSessionsMatchingLeaveItToTheOverseer() {
        let bank = SessionPlace(rowId: "bank", group: "Other", windowId: nil, tab: nil, title: "Mortgage statements for the bank",
                                cwd: "/p/private/bank", isPrivate: true)
        #expect(route("take me to the mortgage statements one", in: sessions + [bank]) == nil)
        #expect(route("take me to the reconcile mortgage statements one", in: sessions + [bank]) == nil)
    }

    @Test func aPublicSessionWithASimilarTitleIsNotTakenOver() {
        #expect(route("take me to scout rashford") == nil)
        #expect(route("tell scout rashford to sign") == nil)
        // Only the private title has "contract".
        #expect(route("take me to the scout rashford contract one") == .goTo(contract))
        let kit = [SessionPlace(rowId: "k", group: "Other", windowId: nil, tab: nil, title: "Kit launch", cwd: "/p/private/k", isPrivate: true),
                   SessionPlace(rowId: "c", group: "Shop", windowId: "w", tab: 1, title: "Kit launch copy for the away shirt", cwd: "/p/shop")]
        #expect(route("go to kit launch copy", in: kit) == nil)
        #expect(route("go to kit launch", in: kit) == nil)
    }

    @Test func takesOutAPromptAfterToOrAColon() {
        #expect(route("tell the reconcile mortgage one to check the March figures") == .send(mortgage, prompt: "check the March figures"))
        #expect(route("ask reconcile mortgage statements: rerun the totals") == .send(mortgage, prompt: "rerun the totals"))
        #expect(route("mortgage statements, add the April payment") == .send(mortgage, prompt: "add the April payment"))
        #expect(route("tell mortgage to reconcile the statements") == .send(mortgage, prompt: "reconcile the statements"))
        #expect(route("tell the reconcile mortgage one that the bank has replied")
                == .send(mortgage, prompt: "the bank has replied"))
    }

    @Test func anInstructionThatDoesNotComeOutCleanlyGoesThereToReply() {
        #expect(route("rebase the reconcile mortgage statements branch") == .goToAndReply(mortgage))
        #expect(route("go to the reconcile mortgage one to check the logs") == .goToAndReply(mortgage))
        #expect(route("tell the reconcile mortgage one about the April payment") == .goToAndReply(mortgage))
        #expect(route("tell the reconcile mortgage one to") == .goTo(mortgage))
        #expect(route("tell the reconcile mortgage one") == .goTo(mortgage))
    }

    @Test func itsCardsAreTheOrdinaryOnesMarkedPrivate() {
        let go = PrivateRoute.goTo(mortgage).card
        #expect(go.kind == .goTo([mortgage], missing: []) && go.isPrivate && go.canSend)
        let send = PrivateRoute.send(mortgage, prompt: "rerun the totals").card
        #expect(send.kind == .send([mortgage], missing: []) && send.prompt == "rerun the totals" && send.isPrivate)
        #expect(PrivateRoute.goToAndReply(mortgage).answer.contains("reply from its page"))
    }
}

/// The real Store's briefing and places; sending and going are recorded, never typed into Ghostty.
@MainActor
private final class StoreHost: OverseerHost {
    let store: Store
    private(set) var sent: [(text: String, sessionId: String, images: [AttachedImage])] = []
    private(set) var wentTo: [String] = []

    init(_ store: Store) { self.store = store }

    func digestBriefing() -> String { store.digestBriefing() }
    var overseerPlaces: [SessionPlace] { store.overseerPlaces }

    func send(_ text: String, images: [AttachedImage], toSession sessionId: String) async -> Bool {
        sent.append((text, sessionId, images))
        return true
    }

    func startSession(prompt: String, images: [AttachedImage], cwd: String, windowId: String?) async -> Ghostty.NewTab? { nil }

    func goTo(session sessionId: String) -> Bool {
        wentTo.append(sessionId)
        return true
    }
}

@MainActor
struct PrivateChatTests {
    /// A window with a private session between two open ones, and a private one with no tab.
    private func store() -> Store {
        let now = Date()
        func row(_ id: String, _ title: String, cwd: String, window: String?, tab: Int?, goal: String, prompt: String, topic: String) -> Row {
            let digest = Digest(goal: goal, state: "Under way", at: now, topic: topic)
            return Row(id: id, title: title, cwd: cwd, status: "idle", statusSince: nil, lastInteraction: now, needsYou: false,
                       prompts: [(now, prompt)], ticket: nil, windowId: window, tab: tab, digest: digest, digestHistory: [digest], topic: topic)
        }
        let approvals = AutoApprovals(demo: AutoApproveSettings(excludedDirectories: ["~/finances"]), log: [], home: "/Users/fan")
        return Store(demoRows: [
            row("scout", "Scout Rashford", cwd: "/Users/fan/Projects/united", window: "w", tab: 1,
                goal: "Write up the scouting report", prompt: "summarise his last five games", topic: "Scouting"),
            row("mortgage", "Reconcile the mortgage statements", cwd: "/Users/fan/finances/mortgage", window: "w", tab: 2,
                goal: "Match the lender's figures", prompt: "list the lender's documents", topic: "Mortgage"),
            row("shop", "Fix flaky checkout test", cwd: "/Users/fan/Projects/shop", window: "w", tab: 3,
                goal: "Stop the checkout test failing", prompt: "run it fifty times", topic: "Shop"),
            row("holiday", "Budget the summer holiday", cwd: "/Users/fan/finances/holiday", window: nil, tab: nil,
                goal: "Price the ferry and the cottage", prompt: "compare the ferry times", topic: "Holiday"),
        ], approvals: approvals)
    }

    /// Anything from the private sessions, or from what was said about them.
    private let secrets = ["reconcile", "mortgage", "statement", "lender", "finances", "budget", "summer", "holiday",
                           "ferry", "cottage", "the totals"]

    private func leaks(_ request: OverseerRequest) -> [String] {
        let told = (request.message + request.systemPrompt).lowercased()
        return secrets.filter { told.contains($0) }
    }

    private func ask(_ chat: OverseerChat, _ host: OverseerHost, _ text: String, images: [AttachedImage] = []) async {
        chat.draft = text
        chat.draftImages = images
        chat.submit(to: host)
        await chat.settle()
    }

    @Test func isAnsweredByTheAppWithAGoCard() async throws {
        let host = FakeHost()
        host.overseerPlaces = sessions
        let runner = FakeRunner([])
        let chat = OverseerChat(runner: runner, file: nil, settingsFile: nil)
        await ask(chat, host, "let's go to the chat talking about reconcile mortgage")
        #expect(runner.requests.isEmpty)
        #expect(chat.conversation.messages.map(\.role) == [.user, .note])
        #expect(chat.conversation.messages.allSatisfy { $0.isPrivate == true })
        #expect(chat.conversation.messages[1].text == "That is a private session, so the overseer cannot see it. I can take you there.")
        let card = try #require(chat.card)
        #expect(card.kind == .goTo([mortgage], missing: []) && card.isPrivate)
        #expect(host.wentTo.isEmpty)
        await chat.confirm(using: host)
        #expect(host.wentTo == ["mortgage"])
        #expect(chat.conversation.messages.last?.text == "Went to Other (Reconcile the mortgage statements).")
        #expect(chat.conversation.messages.last?.isPrivate == true)
    }

    @Test func aPromptForItWaitsOnASendCardWithItsImages() async throws {
        let host = FakeHost()
        host.overseerPlaces = sessions
        let image = AttachedImage(path: "/tmp/lotc-test/attachments/0a1b.png")
        let chat = OverseerChat(runner: FakeRunner([]), file: nil, settingsFile: nil)
        await ask(chat, host, "tell the reconcile mortgage one to check this statement", images: [image])
        let card = try #require(chat.card)
        #expect(card.kind == .send([mortgage], missing: []) && card.prompt == "check this statement" && card.images == [image])
        #expect(host.sent.isEmpty)
        chat.card?.prompt = "check this statement against March"
        await chat.confirm(using: host)
        #expect(host.sent.map(\.text) == ["check this statement against March"])
        #expect(host.sent.map(\.images) == [[image]])
    }

    @Test func twoPrivateMatchesGoToTheOverseer() async {
        let host = FakeHost()
        host.overseerPlaces = sessions + [SessionPlace(rowId: "bank", group: "Other", windowId: nil, tab: nil,
                                                       title: "Mortgage statements for the bank", cwd: "/p/private/bank", isPrivate: true)]
        let runner = FakeRunner([.success("It may be one of the private sessions: pick it in the sidebar.")])
        let chat = OverseerChat(runner: runner, file: nil, settingsFile: nil)
        await ask(chat, host, "take me to the mortgage statements one")
        #expect(runner.requests.count == 1)
        #expect(chat.card == nil)
        #expect(chat.conversation.messages.allSatisfy { $0.isPrivate == nil })
    }

    @Test func nothingFromAPrivateSessionReachesTheOverseer() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lotc-overseer-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = store()
        let host = StoreHost(store)
        #expect(store.groups.map(\.name) == ["shop"])  // never "mortgage", the private session's folder
        #expect(store.overseerPlaces.filter(\.isPrivate).map(\.rowId).sorted() == ["holiday", "mortgage"])

        let runner = FakeRunner([.success("Nobody is waiting."), .success("Still nobody."), .failure(.conversationGone),
                                 .success("Nobody, still.")])
        let chat = OverseerChat(runner: runner, file: file, settingsFile: nil)
        // Answered here: going to one, sending to the other with an image, and cancelling.
        await ask(chat, host, "let's go to the chat talking about reconcile mortgage")
        await chat.confirm(using: host)
        await ask(chat, host, "tell the summer holiday one to price the ferry",
                  images: [AttachedImage(path: "/tmp/lotc-test/attachments/2c3d.jpg")])
        await chat.confirm(using: host)
        await ask(chat, host, "reconcile the mortgage statements: rerun the totals")
        chat.cancelCard()
        #expect(runner.requests.isEmpty)
        #expect(host.wentTo == ["mortgage"] && host.sent.map(\.sessionId) == ["holiday"])

        // The briefing and the since-your-last-answer notes.
        await ask(chat, host, "what needs me?")
        let first = try #require(runner.requests.first)
        #expect(leaks(first) == [])
        #expect(first.images.isEmpty)
        #expect(first.message.contains("2 private sessions are open that you cannot see."))
        #expect(first.message.contains("Scout Rashford") && first.message.contains("## shop"))
        #expect(!first.message.contains("<since-your-last-answer>"))

        // A fresh conversation after new instructions, replaying the chat.
        var saved = OverseerConversation.load(from: file)
        saved.instructions = "an older fingerprint"
        saved.save(to: file)
        let restarted = OverseerChat(runner: runner, file: file, settingsFile: nil)
        await ask(restarted, host, "and now?")
        let replayed = runner.requests[1]
        #expect(!replayed.resume && replayed.message.contains("<earlier-conversation>"))
        #expect(replayed.message.contains("Developer: what needs me?\nYou: Nobody is waiting."))
        #expect(leaks(replayed) == [])

        // A fresh conversation because the old one has gone, replaying the chat again.
        await ask(restarted, host, "and now?")
        #expect(runner.requests.count == 4)
        #expect(runner.requests[3].message.contains("<earlier-conversation>"))
        #expect(runner.requests.map(leaks) == [[], [], [], []])

        // Everything said about them is still on screen.
        #expect(restarted.conversation.messages.contains { $0.text == "let's go to the chat talking about reconcile mortgage" })
    }

    @Test func whatTheOverseerProposesNeverLandsOnAPrivateSession() async throws {
        let host = FakeHost()
        host.overseerPlaces = sessions
        let guess = "Perhaps this.\n```lotc\n{\"action\": \"goto\", \"target\": {\"title\": \"mortgage\"}}\n```"
        let runner = FakeRunner([.success(guess), .success("Fine.")])
        let chat = OverseerChat(runner: runner, file: nil, settingsFile: nil)
        await ask(chat, host, "where are the bank papers?")
        let card = try #require(chat.card)
        #expect(card.kind == .goTo([], missing: ["\"mortgage\""]) && !card.canSend)
        await chat.confirm(using: host)
        #expect(host.wentTo.isEmpty)
    }
}

/// The bug as seen: unsure, two sessions named, and a go-to for one of them.
private let unsureGoTo = """
    None of the briefing titles mention the contract, so I can't be sure which session you mean. The likeliest are \
    [Scout Rashford](session:United/2) or [Scout Fernandes](session:United/3). The app will ask which.
    ```lotc
    {"action": "goto", "target": {"group": "United", "tab": 2, "title": "Scout Rashford"}}
    ```
    """

/// Two windows of made-up sessions, all open to the overseer.
private let squad = [
    SessionPlace(rowId: "a", group: "United", windowId: "w1", tab: 1, title: "Plan the treble", cwd: "/p/united"),
    SessionPlace(rowId: "b", group: "United", windowId: "w1", tab: 2, title: "Scout Rashford", cwd: "/p/united"),
    SessionPlace(rowId: "c", group: "United", windowId: "w1", tab: 3, title: "Scout Fernandes", cwd: "/p/united"),
    SessionPlace(rowId: "d", group: "Shop", windowId: "w2", tab: 1, title: "Fix flaky checkout test", cwd: "/p/shop"),
]

struct UnsureProposalTests {
    private let two = "Either [Scout Rashford](session:United/2) or [Scout Fernandes](session:United/3)."

    @Test func aGoToUnderTwoLinkedSessionsAsksWhich() {
        let proposal = Proposal.goTo(targets: [ProposedTarget(group: "United", tab: 2, title: "Scout Rashford")])
        let checked = proposal.checked(against: two, places: squad)
        #expect(checked == .choose(question: nil, candidates: [ProposedTarget(group: "United", tab: 2, title: "Scout Rashford"),
                                                               ProposedTarget(group: "United", tab: 3, title: "Scout Fernandes")],
                                   prompt: nil))
        #expect(RoutingCard.make(checked, places: squad).kind == .goTo([squad[1], squad[2]], missing: []))
    }

    @Test func aSendUnderTwoLinkedSessionsAsksWhichKeepingItsPrompt() {
        let proposal = Proposal.send(targets: [ProposedTarget(title: "Scout Rashford")], prompt: "write it up")
        let card = RoutingCard.make(proposal.checked(against: two, places: squad), places: squad)
        #expect(card.kind == .choose(question: "Which session?", candidates: [squad[1], squad[2]]))
        #expect(card.prompt == "write it up")
    }

    @Test func itsOwnTargetJoinsTheLinkedOnes() {
        let proposal = Proposal.goTo(targets: [ProposedTarget(title: "Fix flaky checkout test")])
        let card = RoutingCard.make(proposal.checked(against: two, places: squad), places: squad)
        #expect(card.kind == .goTo([squad[3], squad[1], squad[2]], missing: []))
    }

    @Test func oneLinkOrSeveralTargetsAskedForStayAsTheyAre() {
        let go = Proposal.goTo(targets: [ProposedTarget(title: "Scout Rashford")])
        #expect(go.checked(against: "[Scout Rashford](session:United/2) has a draft.", places: squad) == go)
        #expect(go.checked(against: "[Scout Rashford](session:United/2), then [Scout Rashford](session:United/2).", places: squad) == go)
        let both = Proposal.send(targets: [ProposedTarget(title: "Scout Rashford"), ProposedTarget(title: "Scout Fernandes")], prompt: "stop")
        #expect(both.checked(against: two, places: squad) == both)
        let new = Proposal.newSession(group: "Shop", cwd: "/", prompt: "start")
        #expect(new.checked(against: two, places: squad) == new)
    }

    @Test func dropsAPromiseToAskWhenNoChoiceFollows() {
        #expect(AnswerText.withoutPromisedChoice("I can't tell which. The app will ask which.") == "I can't tell which.")
        #expect(AnswerText.withoutPromisedChoice("Two fit. The app asks which one. Both are idle.") == "Two fit. Both are idle.")
        #expect(AnswerText.withoutPromisedChoice("The app will let you pick.") == "The app will let you pick.")
        #expect(AnswerText.withoutPromisedChoice("The diff is in its tab.") == "The diff is in its tab.")
    }

    @MainActor @Test func theBugAsSeenNowAsksWhich() async throws {
        let host = FakeHost()
        host.overseerPlaces = squad
        let chat = OverseerChat(runner: FakeRunner([.success(unsureGoTo)]), file: nil, settingsFile: nil)
        chat.draft = "take me to the contract one"
        chat.submit(to: host)
        await chat.settle()
        let card = try #require(chat.card)
        #expect(card.kind == .goTo([squad[1], squad[2]], missing: []) && card.asksWhich)
        await chat.confirm(using: host)
        #expect(host.wentTo.isEmpty)
        #expect(chat.conversation.messages.last?.text.hasSuffix("The app will ask which.") == true)
        chat.choose(squad[2])
        await chat.confirm(using: host)
        #expect(host.wentTo == ["c"])
    }

    @MainActor @Test func aPromiseWithNoChoiceIsDropped() async {
        let host = FakeHost()
        host.overseerPlaces = squad
        let chat = OverseerChat(runner: FakeRunner([.success("Nothing in the briefing fits. The app will ask which.")]),
                                file: nil, settingsFile: nil)
        chat.draft = "take me to the contract one"
        chat.submit(to: host)
        await chat.settle()
        #expect(chat.card == nil)
        #expect(chat.conversation.messages.last?.text == "Nothing in the briefing fits.")
    }
}
