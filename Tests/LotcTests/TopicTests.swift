import Foundation
import Testing
@testable import LordOfTheClaudes
@testable import LotcKit

struct TopicReplyTests {
    let at = Date(timeIntervalSince1970: 1000)

    @Test func readsTheTopicLine() {
        let digest = DigestReply.parse("""
            GOAL: Book a cottage for half term
            STATE: Four shortlisted
            BLOCKED: none
            TOPIC: "holiday."
            """, at: at)
        #expect(digest == Digest(goal: "Book a cottage for half term", state: "Four shortlisted", at: at, topic: "Holiday"))
    }

    @Test func aReplyWithoutATopicStillGivesADigest() {
        let digest = DigestReply.parse("GOAL: g\nSTATE: s\nBLOCKED: none", at: at)
        #expect(digest == Digest(goal: "g", state: "s", at: at))
        #expect(DigestReply.parse("GOAL: g\nSTATE: s\nTOPIC: none", at: at)?.topic == nil)
    }

    @Test(arguments: [
        ("shop checkout", "Shop checkout"),
        ("  **Tax** ", "Tax"),
        ("Away kit and travel plans for the cup", "Away kit and"),
        ("n/a", nil),
        ("", nil),
    ] as [(String, String?)])
    func tidiesALabel(_ raw: String, _ clean: String?) {
        #expect(Topics.clean(raw) == clean)
    }

    @Test func theSummariserIsOfferedTheTopicsInUse() {
        let input = DigestReply.input("Title: Kit order", topics: TopicContext(current: "Kit", inUse: ["Kit", "Holiday", "Tax"]))
        #expect(input == "Title: Kit order\n\nTopics already in use: Kit; Holiday; Tax\nThis session's topic so far: Kit")
        #expect(DigestReply.input("Title: Kit order", topics: .none) == "Title: Kit order")
        #expect(DigestReply.instructions.contains("copy it exactly"))
    }

    @MainActor @Test func theObserverHandsThemOver() async {
        let summariser = FakeSummariser(.reply("GOAL: g\nSTATE: s\nTOPIC: Kit"))
        var delivered: [Digest] = []
        let observer = Observer(summariser: summariser, read: { Excerpt(text: $0.lastAssistantMessage ?? "", fingerprint: "f") },
                                settle: .zero, topics: { _ in TopicContext(current: nil, inUse: ["Kit"]) }) { _, digest in
            delivered.append(digest)
        }
        observer.stopped(StopEvent(sessionId: "a", lastAssistantMessage: "Ordered."))
        let deadline = Date().addingTimeInterval(5)
        while delivered.isEmpty && Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(summariser.excerpts == ["Ordered.\n\nTopics already in use: Kit"])
        #expect(delivered.first?.topic == "Kit")
    }
}

struct TopicAssignmentTests {
    private func next(_ current: String?, pinned: Bool = false, proposed: String?, previous: String? = nil,
                      inUse: [String] = ["Holiday", "Tax"], aliases: [String: String] = [:]) -> String? {
        Topics.next(current: current, pinned: pinned, proposed: proposed, previous: previous, inUse: inUse, aliases: aliases)
    }

    @Test func aFirstTopicIsTakenSpeltAsTheOneInUse() {
        #expect(next(nil, proposed: "holiday") == "Holiday")
        #expect(next(nil, proposed: "Kit") == "Kit")
        #expect(next(nil, proposed: nil) == nil)
    }

    @Test func aHandSetTopicNeverMoves() {
        #expect(next("Tax", pinned: true, proposed: "Holiday", previous: "Holiday") == "Tax")
    }

    @Test func oneOddDigestMovesNothingButTwoInARowDo() {
        #expect(next("Tax", proposed: "Holiday", previous: nil) == "Tax")
        #expect(next("Tax", proposed: "Holiday", previous: "Tax") == "Tax")
        #expect(next("Tax", proposed: "holiday", previous: "Holiday") == "Holiday")
        #expect(next("Tax", proposed: nil, previous: "Holiday") == "Tax")
    }

    @Test func aRenamedTopicsOldNameLandsInTheNewOne() {
        #expect(next(nil, proposed: "Shop checkout", inUse: ["Checkout"], aliases: ["shop checkout": "Checkout"]) == "Checkout")
    }

    @Test func fallsBackToTheProjectFolder() {
        let row = Row(id: "a", title: "t", cwd: "/Users/fan/Projects/united-kit", status: "idle", statusSince: nil,
                      lastInteraction: Date(), needsYou: false, prompts: [], ticket: nil)
        #expect(row.topicName == "united-kit")
        #expect(Topics.folder(of: "/") == "Sessions")
    }
}

@MainActor
struct TopicStoreTests {
    private let now = Date()

    private func row(_ id: String, topic: String? = nil, pinned: Bool = false, cwd: String = "/p/home") -> Row {
        Row(id: id, title: "Session \(id)", cwd: cwd, status: "idle", statusSince: nil, lastInteraction: now,
            needsYou: false, prompts: [], ticket: nil, windowId: "w", tab: Int(id), topic: topic, topicPinned: pinned)
    }

    private func digest(_ topic: String?) -> Digest { Digest(goal: "g", state: UUID().uuidString, at: now, topic: topic) }

    private func topic(_ store: Store, _ id: String) -> String? { store.rows.first { $0.id == id }?.topic }

    @Test func aDigestFilesASessionAndAPinnedOneStaysPut() {
        let store = Store(demoRows: [row("1"), row("2", topic: "Tax", pinned: true)])
        store.record(digest("Holiday"), for: "1")
        store.record(digest("Holiday"), for: "2")
        store.record(digest("Holiday"), for: "2")
        #expect(topic(store, "1") == "Holiday")
        #expect(topic(store, "2") == "Tax")
    }

    @Test func aSessionMovesTopicOnlyWhenTwoDigestsAgree() {
        let store = Store(demoRows: [row("1", topic: "Tax")])
        store.record(digest("Holiday"), for: "1")
        #expect(topic(store, "1") == "Tax")
        store.record(digest("Holiday"), for: "1")
        #expect(topic(store, "1") == "Holiday")
    }

    @Test func renamingATopicRenamesItEverywhereAndForLater() {
        let store = Store(demoRows: [row("1", topic: "Shop checkout"), row("2", topic: "Shop checkout"), row("3", topic: "Tax"), row("4")])
        store.renameTopic("shop checkout", to: "Checkout")
        #expect(topic(store, "1") == "Checkout" && topic(store, "2") == "Checkout")
        #expect(store.rows.first { $0.id == "1" }?.topicPinned == true)
        store.record(digest("Shop checkout"), for: "4")
        #expect(topic(store, "4") == "Checkout")  // the observer's old label means the new name
        #expect(!store.topicsInUse.contains("Shop checkout"))
    }

    @Test func renamingOntoAnotherTopicMergesThem() {
        let store = Store(demoRows: [row("1", topic: "Taxes"), row("2", topic: "Tax")])
        store.renameTopic("Taxes", to: "Tax")
        #expect(Set(store.rows.map(\.topicName)) == ["Tax"])
    }

    @Test func renamingAFolderGroupNamesItsSessions() {
        let store = Store(demoRows: [row("1", cwd: "/p/kit-room"), row("2", cwd: "/p/kit-room")])
        store.renameTopic("kit-room", to: "Kit")
        #expect(store.rows.map(\.topicName) == ["Kit", "Kit"])
    }

    @Test func movingASessionPinsItThere() {
        let store = Store(demoRows: [row("1", topic: "Holiday"), row("2", topic: "Tax")])
        store.move("1", toTopic: "tax")
        #expect(topic(store, "1") == "Tax")  // spelt as the topic already is
        store.record(digest("Holiday"), for: "1")
        store.record(digest("Holiday"), for: "1")
        #expect(topic(store, "1") == "Tax")
        store.unpinTopic("1")
        store.record(digest("Holiday"), for: "1")
        #expect(topic(store, "1") == "Holiday")  // the last digest proposed it too
    }

    @Test func theObserverIsToldTheSessionsTopicAndEveryOneInUse() {
        let store = Store(demoRows: [row("1", topic: "Tax"), row("2", topic: "Holiday"), row("3", topic: "Holiday"), row("4")])
        #expect(store.topicContext(for: "1") == TopicContext(current: "Tax", inUse: ["Holiday", "Tax"]))
        #expect(store.topicContext(for: "4").current == nil)
    }

    @Test func foldedTopicsAreRemembered() {
        let store = Store(demoRows: [row("1", topic: "Tax")], collapsedTopics: ["Tax"])
        #expect(store.collapsedTopics == ["tax"])
        store.setTopicCollapsed("Tax", false)
        #expect(store.collapsedTopics.isEmpty)
    }

    @Test func anOldStateFileStillLoads() throws {
        let json = """
            {"heartbeat": 0, "records": [{"id": "a", "cwd": "/p/united", "title": "Plan the treble", "lastSeen": 0,
             "lastInteraction": 0, "digest": {"goal": "g", "state": "s", "at": 0}}]}
            """
        let state = try JSONDecoder().decode(SavedState.self, from: Data(json.utf8))
        #expect(state.records[0].topic == nil && state.records[0].topicPinned == nil)
        #expect(state.records[0].digest?.topic == nil)
        #expect(state.topicAliases == nil && state.collapsedTopics == nil)
    }
}

struct TopicGroupTests {
    private let now = Date()

    private func row(_ id: String, _ topic: String, minutesAgo: Double, waiting: Bool = false) -> Row {
        Row(id: id, title: id, cwd: "/p", status: "idle", statusSince: nil, lastInteraction: now.addingTimeInterval(-minutesAgo * 60),
            needsYou: waiting, prompts: [], ticket: nil, windowId: "w", tab: 1, topic: topic)
    }

    @Test func waitingGroupsFirstThenTheMostRecentlyPrompted() {
        let rows = [
            row("a", "Tax", minutesAgo: 1),
            row("b", "Holiday", minutesAgo: 30, waiting: true),
            row("c", "Kit", minutesAgo: 5),
            row("d", "kit", minutesAgo: 90),
            row("e", "Matchday", minutesAgo: 10, waiting: true),
        ]
        let groups = SidebarGroups.byTopic(running: rows, collapsed: ["kit"], matches: { _, _ in true })
        #expect(groups.map(\.name) == ["Matchday", "Holiday", "Tax", "Kit"])
        #expect(groups.map(\.number) == [1, 2, 3, 4])
        #expect(groups[3].all.map(\.id) == ["c", "d"])
        #expect(groups.map(\.collapsed) == [false, false, false, true])
        #expect(groups[3].id == "topic:kit")
    }

    @Test func aLoneTopicCannotFold() {
        let groups = SidebarGroups.byTopic(running: [row("a", "Tax", minutesAgo: 1)], collapsed: ["tax"], matches: { _, _ in true })
        #expect(groups.first?.collapsed == nil)
    }
}
