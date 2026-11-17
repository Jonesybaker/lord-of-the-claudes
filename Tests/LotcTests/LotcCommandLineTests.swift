import Foundation
import Testing
@testable import LotcKit
@testable import lotc

struct LotcCommandLineTests {
    @Test func parsesEveryCommand() throws {
        #expect(try Lotc.parse([]) == .help)
        #expect(try Lotc.parse(["--help"]) == .help)
        #expect(try Lotc.parse(["list"]) == .list(json: false))
        #expect(try Lotc.parse(["list", "--json"]) == .list(json: true))
        #expect(try Lotc.parse(["send", "2", "run the tests"]) == .send(tab: "2", prompt: "run the tests"))
        #expect(try Lotc.parse(["send", "summons", "run", "the", "tests"]) == .send(tab: "summons", prompt: "run the tests"))
        #expect(try Lotc.parse(["broadcast", "pull main"]) == .broadcast(prompt: "pull main"))
        #expect(try Lotc.parse(["wait", "2"]) == .wait(tab: "2", timeout: Lotc.defaultWaitTimeout))
        #expect(try Lotc.parse(["wait", "2", "--timeout", "300"]) == .wait(tab: "2", timeout: 300))
        #expect(try Lotc.parse(["wait", "--timeout=5", "2"]) == .wait(tab: "2", timeout: 5))
        #expect(try Lotc.parse(["last", "3"]) == .last(tab: "3"))
        #expect(try Lotc.parse(["lord"]) == .lord)
        #expect(try Lotc.parse(["hooks", "install"]) == .hooks(.install))
        #expect(try Lotc.parse(["permission"]) == .permission)
        #expect(try Lotc.parse(["observe"]) == .observe)
        #expect(try Lotc.parse(["digest"]) == .digest(tab: nil, all: false))
        #expect(try Lotc.parse(["digest", "2"]) == .digest(tab: "2", all: false))
        #expect(try Lotc.parse(["digest", "--all"]) == .digest(tab: nil, all: true))
    }

    @Test(arguments: [["send", "2"], ["broadcast"], ["wait"], ["wait", "2", "--timeout"], ["wait", "2", "--timeout", "soon"],
                      ["wait", "2", "3"], ["last"], ["lord", "now"], ["hooks"], ["hooks", "remove"], ["list", "--all"], ["frobnicate"],
                      ["digest", "1", "2"], ["digest", "--all", "2"], ["digest", "--json"]])
    func rejectsWhatItCannotUnderstand(_ arguments: [String]) {
        #expect(throws: Lotc.UsageError.self) { try Lotc.parse(arguments) }
    }

    @Test func listsTheWindowAsATableWithEachStateLineUnderItsTitle() {
        func session(_ tab: Int, _ title: String, _ status: String, waiting: Bool = false, lord: Bool = false,
                     me: Bool = false, state: String? = nil) -> SessionSummary {
            SessionSummary(tab: tab, title: title, sessionId: "\(tab)", cwd: "/x", status: status,
                           waitingForYou: waiting, isLord: lord, isCaller: me,
                           digest: state.map { Digest(goal: "g", state: $0, at: Date()) })
        }
        let listing = WindowListing(group: "united", sessions: [
            session(1, "Plan the treble", "busy", lord: true, me: true, state: "League and cup fixtures mapped"),
            session(2, "Scout the Stretford End", "idle", waiting: true),
            session(10, "Old Trafford roof", "idle", state: "Quotes in from three roofers"),
        ])
        #expect(Lotc.table(listing) == """
            united: 3 sessions
            TAB  STATUS   WAITING  LORD  TITLE
            1    working           yes   Plan the treble  (you)
                                         League and cup fixtures mapped
            2    idle     yes            Scout the Stretford End
            10   idle                    Old Trafford roof
                                         Quotes in from three roofers
            """)
    }

    @Test func hookRepliesInTheShapeClaudeCodeReads() {
        #expect(HookReply(.allow)?.json == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        #expect(HookReply(.deny(message: "use the test DB", interrupt: false))?.json
            == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","interrupt":false,"message":"use the test DB"},"hookEventName":"PermissionRequest"}}"#)
        #expect(HookReply(.askInTerminal) == nil)
    }

    @Test func requestsAndResponsesSurviveTheWire() throws {
        let request = LotcRequest(caller: "abc", command: .wait(tab: "2", timeout: 30))
        let decodedRequest = try JSONDecoder().decode(LotcRequest.self, from: JSONEncoder().encode(request))
        #expect(decodedRequest.command == request.command && decodedRequest.caller == "abc")

        let response = LotcResponse.permission(.deny(message: "no", interrupt: true))
        #expect(try JSONDecoder().decode(LotcResponse.self, from: JSONEncoder().encode(response)) == response)

        let stop = LotcRequest(caller: nil, command: .observe(StopEvent(sessionId: "s", transcriptPath: "/t.jsonl",
                                                                        cwd: "/c", lastAssistantMessage: "Done.")))
        #expect(try JSONDecoder().decode(LotcRequest.self, from: JSONEncoder().encode(stop)).command == stop.command)
    }

    @Test func findsTheCallingSessionInTheRegistry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lotc-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let me = getpid()
        let started = ProcessEntry(pid: me)!.startedAt.timeIntervalSince1970 * 1000
        try Data(#"{"pid":\#(me),"sessionId":"live","startedAt":\#(Int(started))}"#.utf8)
            .write(to: dir.appendingPathComponent("\(me).json"))
        try Data(#"{"pid":1,"sessionId":"stale","startedAt":1}"#.utf8).write(to: dir.appendingPathComponent("1.json"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("2.json"))

        let registry = Caller.sessions(in: dir)
        #expect(registry.count == 2)
        #expect(registry[me]?.matches(ProcessEntry(pid: me)!) == true)
        #expect(registry[1]?.matches(ProcessEntry(pid: me)!) == false)
    }
}

struct ObserveCommandTests {
    @Test func standsAsideInTheObserversOwnSummariserRun() {
        var sent: [LotcRequest] = []
        var readStdin = false
        let status = ObserveCommand.run(environment: [ObserverRun.variable: "1"],
                                        readInput: { readStdin = true; return Data() }, send: { sent.append($0) })
        #expect(status == 0 && sent.isEmpty && !readStdin)
        // Returns before it reads stdin or arms its watchdog, so this cannot hang or end the test run.
        #expect(PermissionHookCommand.run(environment: [ObserverRun.variable: "1"]) == 0)
    }

    @Test func passesTheStopOnInOneRequest() {
        var sent: [LotcRequest] = []
        let input = """
            {"session_id":"abc","transcript_path":"/t/abc.jsonl","cwd":"/Users/fan/united","permission_mode":"default",
             "hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Team sheet ready.",
             "background_tasks":[],"session_crons":[]}
            """
        #expect(ObserveCommand.run(environment: [:], readInput: { Data(input.utf8) }, send: { sent.append($0) }) == 0)
        #expect(sent.map(\.command) == [.observe(StopEvent(sessionId: "abc", transcriptPath: "/t/abc.jsonl",
                                                           cwd: "/Users/fan/united", lastAssistantMessage: "Team sheet ready."))])
    }

    @Test(arguments: ["", "not json", "[]", #"{"hook_event_name":"Stop"}"#, #"{"session_id":""}"#])
    func saysNothingAndSendsNothingForJunk(_ input: String) {
        var sent: [LotcRequest] = []
        #expect(ObserveCommand.run(environment: [:], readInput: { Data(input.utf8) }, send: { sent.append($0) }) == 0)
        #expect(sent.isEmpty)
    }

    @Test func keepsTheEndOfALongReply() throws {
        let long = String(repeating: "a", count: 5000) + " Shall I merge?"
        let event = try #require(StopEvent(hookInput: .object([JSONMember("session_id", .string("s")),
                                                               JSONMember("last_assistant_message", .string(long))])))
        #expect(event.lastAssistantMessage?.count == StopEvent.messageCap)
        #expect(event.lastAssistantMessage?.hasSuffix("Shall I merge?") == true)
    }
}
