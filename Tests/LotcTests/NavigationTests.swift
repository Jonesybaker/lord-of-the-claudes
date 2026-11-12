import Foundation
import Testing
@testable import LordOfTheClaudes

struct TabMatchTests {
    typealias Session = (id: String, title: String, cwd: String)
    typealias Tab = (id: String, title: String, cwd: String)

    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let sessions: [Session]
        let tabs: [Tab]
        /// Session id to tab id.
        let expected: [String: String]
    }

    static let cases: [Case] = [
        Case(testDescription: "titled match, whatever the directory",
             sessions: [("a", "Plan the treble", "/u")],
             tabs: [("t1", "✳ Scout Rashford", "/u"), ("t2", "◐ Plan the treble", "/elsewhere")],
             expected: ["a": "t2"]),
        Case(testDescription: "untitled fallback: a new session takes the one Claude Code tab in its directory",
             sessions: [("a", "Plan the treble", "/p/q"), ("b", "carrington", "/p/q")],
             tabs: [("t1", "✳ Plan the treble", "/p/q"), ("t2", "✳ Claude Code", "/p/q/")],
             expected: ["a": "t1", "b": "t2"]),
        Case(testDescription: "two untitled sessions in one directory: no guess",
             sessions: [("a", "carrington", "/p/q"), ("b", "carrington", "/p/q")],
             tabs: [("t1", "✳ Claude Code", "/p/q"), ("t2", "✳ Claude Code", "/p/q")],
             expected: [:]),
        Case(testDescription: "two untitled sessions, one tab: no guess",
             sessions: [("a", "carrington", "/p/q"), ("b", "first prompt", "/p/q")],
             tabs: [("t1", "✳ Claude Code", "/p/q")],
             expected: [:]),
        Case(testDescription: "one untitled session, two tabs: no guess",
             sessions: [("a", "carrington", "/p/q")],
             tabs: [("t1", "✳ Claude Code", "/p/q"), ("t2", "✳ Claude Code", "/p/q")],
             expected: [:]),
        Case(testDescription: "untitled session in another directory",
             sessions: [("a", "carrington", "/p/q")],
             tabs: [("t1", "✳ Claude Code", "/p/other")],
             expected: [:]),
        Case(testDescription: "a shell tab is never a session's",
             sessions: [("a", "carrington", "/p/q")],
             tabs: [("t1", "mj@mac:~/p/q", "/p/q")],
             expected: [:]),
        Case(testDescription: "duplicate titles told apart by directory",
             sessions: [("a", "Backup status", "/p/one"), ("b", "Backup status", "/p/two")],
             tabs: [("t1", "✳ Backup status", "/p/two"), ("t2", "✳ Backup status", "/p/one")],
             expected: ["a": "t2", "b": "t1"]),
        Case(testDescription: "duplicate titles in one directory: no guess",
             sessions: [("a", "Backup status", "/p/q"), ("b", "Backup status", "/p/q")],
             tabs: [("t1", "✳ Backup status", "/p/q"), ("t2", "✳ Backup status", "/p/q")],
             expected: [:]),
        Case(testDescription: "duplicate titles, one tab: no guess, and no untitled session takes it",
             sessions: [("a", "Scout Rashford", "/u"), ("b", "Scout Rashford", "/u"), ("c", "united", "/u")],
             tabs: [("t1", "✳ Scout Rashford", "/u")],
             expected: [:]),
    ]

    @Test(arguments: cases)
    func pairsOnlyWhenCertain(_ c: Case) {
        let tabs = c.tabs.map { GhosttyTerminal(id: $0.id, windowId: "w", title: $0.title, cwd: $0.cwd) }
        let pairs = TabMatch.pair(c.sessions.map { TabMatch.Session(id: $0.id, title: $0.title, cwd: $0.cwd) }, with: tabs)
        #expect(pairs.mapValues(\.id) == c.expected)
    }
}

struct WaitingTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        var status = "idle"
        let changed: Double
        var started: Double? = 1000
        let seen: Double?
        var prompted: Double? = nil
        let waiting: Bool
    }

    static let cases: [Case] = [
        Case(testDescription: "still working", status: "busy", changed: 2000, seen: 1500, waiting: false),
        Case(testDescription: "finished after the user last looked", changed: 2000, seen: 1500, prompted: 1400, waiting: true),
        Case(testDescription: "user looked after it finished", changed: 2000, seen: 2100, waiting: false),
        Case(testDescription: "user prompted it after the status change", changed: 2000, seen: 1500, prompted: 2100, waiting: false),
        Case(testDescription: "resumed after a restart and idle since", changed: 2000.2, started: 2000, seen: 500, waiting: false),
        Case(testDescription: "start-up noise just after a resume", changed: 2009, started: 2000, seen: 500, waiting: false),
        Case(testDescription: "real work after a resume", changed: 2300, started: 2000, seen: 2001, prompted: 2010, waiting: true),
        Case(testDescription: "never seen yet", changed: 2000, seen: nil, waiting: false),
        Case(testDescription: "no start time in its file", changed: 2000, started: nil, seen: 1500, waiting: true),
    ]

    @Test(arguments: cases)
    func flagsOnlyWorkFinishedOutOfSight(_ c: Case) {
        func date(_ t: Double?) -> Date? { t.map(Date.init(timeIntervalSince1970:)) }
        #expect(Waiting.needsYou(status: c.status, statusChangedAt: date(c.changed)!, startedAt: date(c.started),
                                 seenAt: date(c.seen), lastPromptAt: date(c.prompted)) == c.waiting)
    }
}

struct ThrowawayTests {
    @Test(arguments: [
        ("/private/tmp/claude-501/scratchpad/e2e", true),
        ("/tmp", true),
        ("/tmp/united", true),
        ("/tmpfoo", false),
        ("/var/folders/r3/xyz/T/run", true),
        ("/private/var/folders/r3/xyz/T", true),
        ("/Users/mj/Projects/united", false),
        ("/Users/mj/scratch/a", true),
        ("/Users/mj/scratchpad", false),
    ])
    func spotsTemporaryDirectories(cwd: String, temporary: Bool) {
        #expect(Throwaway.isTemporary(cwd, tmpdir: "/Users/mj/scratch/") == temporary)
    }
}

struct GroupNamesTests {
    @Test func numbersRepeatsInWindowOrderAndLeavesGivenNamesAlone() {
        #expect(GroupNames.distinct([(nil, "carrington"), (nil, "carrington")]) == ["carrington", "carrington 2"])
        #expect(GroupNames.distinct([(nil, "carrington"), ("Ops", "x"), (nil, "carrington"), (nil, "carrington")])
                == ["carrington", "Ops", "carrington 2", "carrington 3"])
        #expect(GroupNames.distinct([(nil, "carrington"), ("carrington", "x")]) == ["carrington 2", "carrington"])
        #expect(GroupNames.distinct([("Ops", "a"), ("Ops", "b")]) == ["Ops", "Ops"])
        #expect(GroupNames.distinct([(nil, "shop"), (nil, "infra")]) == ["shop", "infra"])
    }
}

struct SectionJumpTests {
    let sections = [["a1", "a2"], ["b1", "b2"], ["c1"]]

    @Test func jumpsToTheFirstRowOfTheNextOrPreviousSectionAndStopsAtTheEnds() {
        #expect(SectionJump.target(from: "b2", by: 1, in: sections) == "c1")
        #expect(SectionJump.target(from: "b2", by: -1, in: sections) == "a1")
        #expect(SectionJump.target(from: "c1", by: 1, in: sections) == "c1")
        #expect(SectionJump.target(from: "a2", by: -1, in: sections) == "a1")
        #expect(SectionJump.target(from: nil, by: 1, in: sections) == "b1")
        #expect(SectionJump.target(from: "a1", by: 1, in: []) == nil)
    }

    @Test func movesOffRowsGoingOutOfSight() {
        let order = ["a1", "a2", "b1", "b2", "c1"]
        #expect(SectionJump.survivor(of: "b2", hiding: ["b1", "b2"], in: order) == "c1")
        #expect(SectionJump.survivor(of: "b1", hiding: ["b1", "b2", "c1"], in: order) == "a2")
        #expect(SectionJump.survivor(of: "a1", hiding: Set(order), in: order) == nil)
    }
}

@MainActor
struct StoreGroupTests {
    private func row(_ id: String, _ cwd: String, window: String, tab: Int) -> Row {
        Row(id: id, title: "Session \(id)", cwd: "/p/" + cwd, status: "idle", statusSince: nil, lastInteraction: Date(),
            needsYou: false, prompts: [], ticket: nil, windowId: window, tab: tab)
    }

    @Test func twoWindowsInOneProjectGetNumberedNamesAndFoldIndependently() {
        let store = Store(demoRows: [row("1", "carrington", window: "w1", tab: 1), row("2", "carrington", window: "w2", tab: 1),
                                     row("3", "united", window: "w3", tab: 1)],
                          groupNames: ["w3": "Old Trafford"], collapsed: ["w2"])
        #expect(store.groups.map(\.name) == ["carrington", "carrington 2", "Old Trafford"])
        #expect(store.groups.map(\.collapsed) == [false, true, false])

        store.setCollapsed("w2", false)
        store.setCollapsed("w1", true)
        #expect(store.groups.map(\.collapsed) == [true, false, false])
    }
}
