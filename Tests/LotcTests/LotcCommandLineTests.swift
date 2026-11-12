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
    }

    @Test(arguments: [["send", "2"], ["broadcast"], ["wait"], ["wait", "2", "--timeout"], ["wait", "2", "--timeout", "soon"],
                      ["wait", "2", "3"], ["last"], ["lord", "now"], ["hooks"], ["hooks", "remove"], ["list", "--all"], ["frobnicate"]])
    func rejectsWhatItCannotUnderstand(_ arguments: [String]) {
        #expect(throws: Lotc.UsageError.self) { try Lotc.parse(arguments) }
    }

    @Test func listsTheWindowAsATable() {
        func session(_ tab: Int, _ title: String, _ status: String, waiting: Bool = false, lord: Bool = false, me: Bool = false) -> SessionSummary {
            SessionSummary(tab: tab, title: title, sessionId: "\(tab)", cwd: "/x", status: status,
                           waitingForYou: waiting, isLord: lord, isCaller: me)
        }
        let listing = WindowListing(group: "united", sessions: [
            session(1, "Plan the treble", "busy", lord: true, me: true),
            session(2, "Scout the Stretford End", "idle", waiting: true),
            session(10, "Old Trafford roof", "idle"),
        ])
        #expect(Lotc.table(listing) == """
            united: 3 sessions
            TAB  STATUS   WAITING  LORD  TITLE
            1    working           yes   Plan the treble  (you)
            2    idle     yes            Scout the Stretford End
            10   idle                    Old Trafford roof
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
