import Foundation
import Testing
@testable import LordOfTheClaudes
@testable import LotcKit

/// Stands in for `claude -p`: holds each run until the test lets it go, then replies.
final class FakeSummariser: Summariser, @unchecked Sendable {
    enum Behaviour { case reply(String), fail, hang }

    private let lock = NSLock()
    private let behaviour: Behaviour
    private var held: [CheckedContinuation<Void, Never>] = []
    private var seen: [String] = []
    private let holds: Bool

    init(_ behaviour: Behaviour = .reply("GOAL: Win the league\nSTATE: Top by two points\nBLOCKED: none"), holds: Bool = false) {
        self.behaviour = behaviour
        self.holds = holds
    }

    var excerpts: [String] { lock.withLock { seen } }
    var holding: Int { lock.withLock { held.count } }

    func release() {
        lock.withLock { held.isEmpty ? nil : held.removeFirst() }?.resume()
    }

    func summarise(_ excerpt: String) async throws -> String {
        lock.withLock { seen.append(excerpt) }
        if holds { await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } } }
        switch behaviour {
        case .reply(let text): return text
        case .fail: throw CancellationError()
        case .hang:
            try await Task.sleep(for: .seconds(60))
            return ""
        }
    }
}

@MainActor
struct ObserverTests {
    /// The excerpt is the stop's last message, and so is its fingerprint, unless the test says otherwise.
    private func observer(_ summariser: FakeSummariser, fingerprint: String? = nil, timeout: Duration = .seconds(5),
                          delivered: @escaping @MainActor (String, Digest) -> Void = { _, _ in }) -> Observer {
        Observer(summariser: summariser,
                 read: { Excerpt(text: $0.lastAssistantMessage ?? "", fingerprint: fingerprint ?? $0.lastAssistantMessage ?? "") },
                 settle: .zero, timeout: timeout, deliver: delivered)
    }

    private func stop(_ session: String, _ text: String) -> StopEvent {
        StopEvent(sessionId: session, lastAssistantMessage: text)
    }

    private func until(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func aNewerStopReplacesTheQueuedOneAndRunsOnceTheFirstIsDone() async {
        let summariser = FakeSummariser(holds: true)
        var digests: [String] = []
        let observer = observer(summariser) { id, _ in digests.append(id) }

        observer.stopped(stop("a", "first"))
        await until { summariser.holding == 1 }
        observer.stopped(stop("a", "second"))
        observer.stopped(stop("a", "third"))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(summariser.excerpts == ["first"])  // one run per session at a time

        summariser.release()
        await until { summariser.holding == 1 && summariser.excerpts.count == 2 }
        #expect(summariser.excerpts == ["first", "third"])
        summariser.release()
        await until { observer.isIdle }
        #expect(digests == ["a", "a"])
    }

    @Test func runsAtMostTwoAtOnce() async {
        let summariser = FakeSummariser(holds: true)
        let observer = observer(summariser)
        for session in ["a", "b", "c"] { observer.stopped(stop(session, session)) }
        await until { summariser.holding == 2 }
        try? await Task.sleep(for: .milliseconds(30))
        // The two runs start on separate threads, so either may reach the summariser first.
        #expect(summariser.excerpts.sorted() == ["a", "b"])

        summariser.release()
        await until { summariser.excerpts.count == 3 }
        #expect(summariser.excerpts.last == "c")
        summariser.release()
        summariser.release()
        await until { observer.isIdle }
        #expect(observer.isIdle)
    }

    @Test func skipsATranscriptItHasAlreadySummarised() async {
        let summariser = FakeSummariser()
        var delivered = 0
        let observer = observer(summariser, fingerprint: "unchanged") { _, _ in delivered += 1 }
        observer.stopped(stop("a", "one"))
        await until { observer.isIdle && delivered == 1 }
        observer.stopped(stop("a", "two"))
        await until { observer.isIdle }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(summariser.excerpts == ["one"])
        #expect(delivered == 1)
    }

    @Test(arguments: [FakeSummariser.Behaviour.fail, .hang, .reply("Sorry, I cannot see a transcript.")])
    func aFailedSlowOrUnreadableRunLeavesTheDigestAlone(_ behaviour: FakeSummariser.Behaviour) async {
        let summariser = FakeSummariser(behaviour)
        var delivered = 0
        let observer = observer(summariser, timeout: .milliseconds(50)) { _, _ in delivered += 1 }
        observer.stopped(stop("a", "one"))
        await until { summariser.excerpts.count == 1 && observer.isIdle }
        #expect(observer.isIdle)
        #expect(delivered == 0)
        // Nothing was summarised, so the same transcript is tried again on the next stop.
        observer.stopped(stop("a", "one"))
        await until { summariser.excerpts.count == 2 && observer.isIdle }
        #expect(summariser.excerpts.count == 2)
    }

    @Test func aStopWithNothingToReadCostsNoRun() async {
        let summariser = FakeSummariser()
        let observer = Observer(summariser: summariser, read: { _ in nil }, settle: .zero) { _, _ in }
        observer.stopped(stop("a", "one"))
        await until { observer.isIdle }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(summariser.excerpts.isEmpty)
    }
}

extension FakeSummariser.Behaviour: CustomTestStringConvertible {
    var testDescription: String {
        switch self {
        case .reply: return "junk reply"
        case .fail: return "fails"
        case .hang: return "hangs past the deadline"
        }
    }
}

struct DigestReplyTests {
    let at = Date(timeIntervalSince1970: 1000)

    @Test func readsTheThreeLines() {
        let digest = DigestReply.parse("""
            GOAL: Sign Rashford's replacement before the window shuts
            STATE: Two bids drafted, waiting on the medical
            BLOCKED: Your yes to the higher bid
            """, at: at)
        #expect(digest == Digest(goal: "Sign Rashford's replacement before the window shuts",
                                 state: "Two bids drafted, waiting on the medical",
                                 blockedOn: "Your yes to the higher bid", at: at))
    }

    @Test func copesWithMarkdownChatterAndOddCase() {
        let digest = DigestReply.parse("""
            Here is the digest:

            - **Goal:** "Repaint the Stretford End seats"
            * state:   Half the rows done,   the rest   on Monday
            **Blocked on**: None.
            GOAL: a second goal line is ignored
            """, at: at)
        #expect(digest == Digest(goal: "Repaint the Stretford End seats",
                                 state: "Half the rows done, the rest on Monday", blockedOn: nil, at: at))
    }

    @Test(arguments: ["none", "None", "nothing", "N/A", "-", "(none)", "Nothing."])
    func treatsEveryWayOfSayingNothingAsNotBlocked(_ nothing: String) {
        #expect(DigestReply.parse("GOAL: g\nSTATE: s\nBLOCKED: \(nothing)", at: at)?.blockedOn == nil)
    }

    @Test(arguments: ["", "I can't help with that.", "GOAL: only a goal", "STATE: only a state",
                      "GOAL:\nSTATE: s", #"{"goal":"g","state":"s"}"#])
    func refusesAReplyWithoutAGoalAndAState(_ reply: String) {
        #expect(DigestReply.parse(reply, at: at) == nil)
    }

    @Test func cutsALongLine() throws {
        let digest = try #require(DigestReply.parse("GOAL: \(String(repeating: "x", count: 500))\nSTATE: s", at: at))
        #expect(digest.goal.count == DigestReply.lineCap)
        #expect(digest.goal.hasSuffix("…"))
    }

    @Test func unwrapsClaudesJSONResult() {
        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"GOAL: g\nSTATE: s","session_id":"x"}"#
        #expect(DigestReply.result(fromJSON: Data(ok.utf8)) == "GOAL: g\nSTATE: s")
        let failed = #"{"type":"result","is_error":true,"result":"Not logged in"}"#
        #expect(DigestReply.result(fromJSON: Data(failed.utf8)) == nil)
        #expect(DigestReply.result(fromJSON: Data("GOAL: g".utf8)) == nil)
        #expect(DigestReply.result(fromJSON: Data(#"{"type":"system"}"#.utf8)) == nil)
    }
}

struct DigestHistoryTests {
    private func digest(_ state: String, _ minute: Double, blockedOn: String? = nil) -> Digest {
        Digest(goal: "g", state: state, blockedOn: blockedOn, at: Date(timeIntervalSince1970: minute * 60))
    }

    @Test func addsAStepOnlyWhenTheStateMovesOn() {
        var history: [Digest] = []
        history = Digest.history(history, adding: digest("Kit ordered", 1))
        history = Digest.history(history, adding: digest("Kit ordered", 2, blockedOn: "Which sponsor"))
        history = Digest.history(history, adding: digest("Kit delivered", 3))
        #expect(history == [digest("Kit ordered", 2, blockedOn: "Which sponsor"), digest("Kit delivered", 3)])
    }

    @Test func keepsTheNewestTwenty() {
        let history = (1...25).reduce([Digest]()) { Digest.history($0, adding: digest("step \($1)", Double($1))) }
        #expect(history.count == Digest.historyLimit)
        #expect(history.first?.state == "step 6")
        #expect(history.last?.state == "step 25")
    }
}

struct TranscriptExcerptTests {
    private func lines(_ items: [String]) -> Data { Data(items.joined(separator: "\n").utf8) }

    private let transcript = [
        #"t","message":{"role":"user","content":"cut in half by reading from the middle"}}"#,
        #"{"type":"ai-title","aiTitle":"Plan the treble"}"#,
        #"{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"plan the treble season"}}"#,
        #"{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"injected by Claude Code"}]}}"#,
        #"{"type":"assistant","message":{"id":"m1","content":[{"type":"thinking","thinking":"hmm"}]}}"#,
        #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Looking at the fixtures."}]}}"#,
        #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"grep -c Arsenal fixtures.csv\nexit","description":"Count"}}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"2"}]}}"#,
        #"{"type":"assistant","isSidechain":true,"message":{"id":"s","content":[{"type":"text","text":"a subagent talking"}]}}"#,
        #"{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"Background task finished"}}"#,
        #"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"Fixtures mapped. Shall I book the coach?"}]}}"#,
    ]

    @Test func keepsWhatWasSaidAndDoneAndDropsTheRest() {
        #expect(Transcript.turns(in: lines(transcript)) == [
            .user("plan the treble season"),
            .claude("Looking at the fixtures."),
            .tool("Bash: grep -c Arsenal fixtures.csv"),
            .note("Background task finished"),
            .claude("Fixtures mapped. Shall I book the coach?"),
        ])
    }

    @Test func readsAsTheSummariserSeesIt() {
        let text = Transcript.excerpt(tail: lines(transcript), head: nil, cwd: "/Users/fan/united",
                                      lastMessage: "Fixtures mapped. Shall I book the coach?")
        #expect(text == """
            Title: Plan the treble
            Working directory: /Users/fan/united

            The latest part of the transcript, oldest first:
            User: plan the treble season
            Claude: Looking at the fixtures.
            Claude ran Bash: grep -c Arsenal fixtures.csv
            Message to Claude: Background task finished
            Claude: Fixtures mapped. Shall I book the coach?
            """)
    }

    @Test func addsTheLastReplyWhenTheTranscriptHasNotCaughtUp() throws {
        let behind = Array(transcript.dropLast())
        let text = try #require(Transcript.excerpt(tail: lines(behind), head: nil, cwd: nil, lastMessage: "Coach booked."))
        #expect(text.hasSuffix("Message to Claude: Background task finished\nClaude: Coach booked."))
    }

    @Test func namesTheFirstPromptWhenTheTailCannotReachIt() throws {
        let head = lines([#"{"type":"user","message":{"role":"user","content":"win the league"}}"#])
        let text = try #require(Transcript.excerpt(tail: lines(transcript), head: head, cwd: nil, lastMessage: nil))
        #expect(text.contains("First prompt: win the league\n"))
    }

    @Test func staysWithinItsBounds() throws {
        let chatter = (1...200).map { n in
            #"{"type":"user","message":{"role":"user","content":"prompt \#(n) \#(String(repeating: "z", count: 3000))"}}"#
        }
        let text = try #require(Transcript.excerpt(tail: lines(chatter), head: nil, cwd: nil, lastMessage: nil))
        #expect(text.count <= Transcript.excerptCharacters + 200)
        #expect(text.contains("prompt 200 "))
        #expect(!text.contains("prompt 160 "))  // only the last 40 turns are read
        #expect(text.contains("[...]"))
    }

    @Test func hasNothingToSayForAnEmptyTranscript() {
        #expect(Transcript.excerpt(tail: Data(), head: nil, cwd: "/x", lastMessage: nil) == nil)
    }
}

struct DigestBriefingTests {
    let now = Date(timeIntervalSince1970: 100_000)

    private func row(_ tab: Int?, _ title: String, status: String = "idle", waiting: Bool = false, lord: Bool = false,
                     digest: Digest? = nil) -> Row {
        Row(id: title, title: title, cwd: "/Users/fan/Projects/united", status: status, statusSince: nil,
            lastInteraction: now, needsYou: waiting, prompts: [], ticket: nil, windowId: "w", tab: tab, isLord: lord,
            digest: digest)
    }

    @Test func listsEverySessionWindowByWindowForAModelToRead() {
        let scouting = Digest(goal: "Shortlist three centre-backs", state: "Two watched, one to go",
                              blockedOn: "Budget for the third", at: now.addingTimeInterval(-12 * 60))
        let kit = Digest(goal: "Order the away kit", state: "Order placed", at: now.addingTimeInterval(-20))
        let text = DigestBriefing.text([
            .init(name: "Scouting", rows: [row(1, "Centre-backs", waiting: true, lord: true, digest: scouting),
                                           row(2, "Youth team", status: "busy")]),
            .init(name: "Kit room", rows: [row(1, "Away kit", digest: kit)]),
            .init(name: "Other", rows: []),
        ], now: now, home: "/Users/fan")
        #expect(text == """
            3 sessions in 2 windows, 1 waiting for you.

            ## Scouting
            tab 1: Centre-backs [idle, waiting for you, lord]
              cwd: ~/Projects/united
              goal: Shortlist three centre-backs
              state: Two watched, one to go
              blocked on: Budget for the third
              summarised: 12m ago
            tab 2: Youth team [working]
              cwd: ~/Projects/united
              no digest yet

            ## Kit room
            tab 1: Away kit [idle]
              cwd: ~/Projects/united
              goal: Order the away kit
              state: Order placed
              blocked on: nothing
              summarised: just now
            """)
    }

    @Test func saysSoWhenNothingIsOpen() {
        #expect(DigestBriefing.text([.init(name: "Other", rows: [])], now: now) == "No Claude Code sessions are open.")
    }

    @MainActor @Test func theStoreBriefsEveryWindowItShows() {
        let digest = Digest(goal: "Plan the parade", state: "Route agreed", at: Date())
        let store = Store(demoRows: [row(1, "Parade", digest: digest)], groupNames: ["w": "United"])
        let text = store.digestBriefing()
        #expect(text.hasPrefix("1 session in 1 window, 0 waiting for you.\n\n## United\ntab 1: Parade [idle]"))
        #expect(text.contains("  state: Route agreed\n"))
    }
}

struct ClaudeLocatorTests {
    @Test func looksOnPathThenInTheUsualPlacesThenOnTheLoginShellsPath() {
        var shellAsked = 0
        func find(_ present: Set<String>, path: String? = "/usr/bin:/bin", shell: String? = nil) -> String? {
            ClaudeLocator.find(path: path, home: "/Users/fan", isExecutable: present.contains,
                               loginShellPath: { shellAsked += 1; return shell })
        }
        #expect(find(["/bin/claude", "/Users/fan/.local/bin/claude"]) == "/bin/claude")
        #expect(find(["/Users/fan/.local/bin/claude", "/opt/homebrew/bin/claude"]) == "/Users/fan/.local/bin/claude")
        #expect(shellAsked == 0)  // starting a shell is the slow way, kept for last
        #expect(find(["/opt/fan/bin/claude"], path: nil, shell: "/opt/fan/bin:/usr/bin") == "/opt/fan/bin/claude")
        #expect(find([], shell: "/usr/bin") == nil)
        #expect(shellAsked == 2)
    }

    @Test func findsThePathLineAmongWhateverTheProfilePrints() {
        let output = "Welcome back!\nLOTC_PATH=decoy\n\u{1b}[0m\nLOTC_PATH=/opt/homebrew/bin:/usr/bin\n"
        #expect(ClaudeLocator.path(inShellOutput: output) == "/opt/homebrew/bin:/usr/bin")
        #expect(ClaudeLocator.path(inShellOutput: "no marker here") == nil)
    }

    @Test func knowsItsOwnSummariserRunsByTheirDirectory() {
        #expect(ClaudeSummariser.isOwnRun(cwd: ClaudeSummariser.workingDirectory.path))
        #expect(!ClaudeSummariser.isOwnRun(cwd: "/Users/fan/Projects/united"))
    }
}
