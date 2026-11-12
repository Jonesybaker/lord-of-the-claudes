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

@MainActor
struct StoreGroupTests {
    private func row(_ id: String, _ cwd: String, window: String, tab: Int) -> Row {
        Row(id: id, title: "Session \(id)", cwd: "/p/" + cwd, status: "idle", statusSince: nil, lastInteraction: Date(),
            needsYou: false, prompts: [], ticket: nil, windowId: window, tab: tab)
    }

    @Test func twoWindowsInOneProjectGetNumberedNames() {
        let store = Store(demoRows: [row("1", "carrington", window: "w1", tab: 1), row("2", "carrington", window: "w2", tab: 1),
                                     row("3", "united", window: "w3", tab: 1)],
                          groupNames: ["w3": "Old Trafford"])
        #expect(store.groups.map(\.name) == ["carrington", "carrington 2", "Old Trafford"])
    }
}
