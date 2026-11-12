import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import LordOfTheClaudes
@testable import LotcKit

struct TranscriptTests {
    private func line(_ id: String?, _ blocks: String, sidechain: Bool = false) -> String {
        let idField = id.map { #""id":"\#($0)","# } ?? ""
        return #"{"type":"assistant","isSidechain":\#(sidechain),"message":{\#(idField)"role":"assistant","content":[\#(blocks)]}}"#
    }

    @Test func joinsEveryTextBlockOfTheLastMessageThatHasText() {
        let transcript = [
            line("m1", #"{"type":"text","text":"old answer"}"#),
            #"{"type":"user","message":{"role":"user","content":"next"}}"#,
            line("m2", #"{"type":"thinking","thinking":"hmm"}"#),
            line("m2", #"{"type":"text","text":"First part."}"#),
            line("m2", #"{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls"}}"#),
            line("m2", #"{"type":"text","text":"Second part."}"#),
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            line("m3", #"{"type":"tool_use","id":"u","name":"Read","input":{}}"#),
            #"{"type":"last-prompt"}"#,
        ].joined(separator: "\n")
        #expect(Transcript.lastAssistantText(in: Data(transcript.utf8)) == "First part.\n\nSecond part.")
    }

    @Test func skipsSubagentMessagesAndCopesWithPlainStrings() {
        let transcript = [
            #"{"type":"assistant","message":{"id":"a","content":"plain answer"}}"#,
            line("b", #"{"type":"text","text":"from a subagent"}"#, sidechain: true),
        ].joined(separator: "\n")
        #expect(Transcript.lastAssistantText(in: Data(transcript.utf8)) == "plain answer")
    }

    @Test func saysNothingWhenThereIsNothing() {
        #expect(Transcript.lastAssistantText(in: Data(#"{"type":"user","message":{"content":"hi"}}"#.utf8)) == nil)
    }
}

struct TurnCheckTests {
    let sent = Date(timeIntervalSince1970: 1000)

    @Test(arguments: [
        ("busy", 1500.0, true, false),  // still on it
        ("idle", 900.0, true, false),  // idle since before the prompt: not started yet
        ("idle", 1500.0, true, true),  // went idle after the prompt
        ("idle", 900.0, false, true),  // nothing sent: idle is enough
        ("busy", 900.0, false, false),
    ])
    func finishedMeansNotBusyAndChangedSinceTheSend(status: String, changedAt: Double, wasSent: Bool, finished: Bool) {
        #expect(TurnCheck.hasFinished(status: status, statusChangedAt: Date(timeIntervalSince1970: changedAt),
                                      sentAt: wasSent ? sent : nil) == finished)
    }
}

struct SessionTargetTests {
    private func row(_ tab: Int, _ title: String) -> Row {
        Row(id: "\(tab)", title: title, cwd: "/x", status: "idle", statusSince: nil, lastInteraction: Date(),
            needsYou: false, prompts: [], ticket: nil, windowId: "w", tab: tab)
    }

    private var rows: [Row] { [row(1, "Plan the treble"), row(2, "Scout Rashford"), row(3, "Scout Fernandes")] }

    @Test func findsByTabNumberOrUniqueTitlePiece() throws {
        #expect(try SessionTarget.find("2", in: rows).get().id == "2")
        #expect(try SessionTarget.find("treble", in: rows).get().id == "1")
        #expect(try SessionTarget.find("FERNANDES", in: rows).get().id == "3")
    }

    @Test(arguments: ["9", "scout", "liverpool", "  "])
    func refusesWhatIsMissingOrAmbiguous(_ target: String) {
        #expect(throws: SessionTarget.Problem.self) { try SessionTarget.find(target, in: rows).get() }
    }
}

struct PermissionKeyTests {
    private func key(_ code: Int, _ characters: String, _ modifiers: NSEvent.ModifierFlags, repeating: Bool = false) -> PermissionKey? {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: UInt16(code))!
        return PermissionKey(event)
    }

    @Test func onlyTheDeliberateChordsAnswer() {
        #expect(key(kVK_Return, "\r", .command) == .approve)
        #expect(key(kVK_ANSI_KeypadEnter, "\u{3}", .command) == .approve)
        #expect(key(kVK_ANSI_D, "d", .command) == .deny)
        #expect(key(kVK_Escape, "\u{1b}", []) == .answerInTerminal)
    }

    @Test func plainReturnAndNearMissesDoNothing() {
        #expect(key(kVK_Return, "\r", []) == nil)
        #expect(key(kVK_Return, "\r", [.command, .shift]) == nil)
        #expect(key(kVK_ANSI_D, "d", []) == nil)
        #expect(key(kVK_ANSI_D, "d", [.command, .option]) == nil)
        #expect(key(kVK_Escape, "\u{1b}", .command) == nil)
    }
}

struct PermissionInputTests {
    @Test func readsTheHookInputAndPreviewsEachToolReadably() throws {
        let input = try #require(PermissionHookInput(json: """
            {"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/Users/mj/united","permission_mode":"default",
             "hook_event_name":"PermissionRequest","tool_name":"Bash",
             "tool_input":{"command":"rm -rf build","description":"Clear the build"},"agent_type":"Explore"}
            """))
        #expect(input.sessionId == "s1" && input.cwd == "/Users/mj/united" && input.agentType == "Explore")
        #expect(ToolPreview(toolName: input.toolName, input: input.toolInput) == .command("rm -rf build", description: "Clear the build"))

        let edit = try JSONValue(parsing: #"{"file_path":"/a.swift","old_string":"x","new_string":"y","replace_all":true}"#)
        #expect(ToolPreview(toolName: "Edit", input: edit) == .edit(file: "/a.swift", old: "x", new: "y", everyOccurrence: true))
        let write = try JSONValue(parsing: #"{"file_path":"/b.md","content":"hello"}"#)
        #expect(ToolPreview(toolName: "Write", input: write) == .write(file: "/b.md", content: "hello"))
        let fetch = try JSONValue(parsing: #"{"url":"https://example.com","prompt":"summarise"}"#)
        #expect(ToolPreview(toolName: "WebFetch", input: fetch) == .json("{\n  \"url\": \"https://example.com\",\n  \"prompt\": \"summarise\"\n}"))
    }

    @Test func ignoresInputThatIsNotAPermissionRequest() {
        #expect(PermissionHookInput(json: "not json") == nil)
        #expect(PermissionHookInput(json: #"{"session_id":"s1"}"#) == nil)
    }
}

@MainActor
struct PermissionQueueTests {
    private func request() -> PermissionQueue.Request {
        PermissionQueue.Request(
            input: PermissionHookInput(json: #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#)!,
            origin: .init(sessionId: nil, label: "x", detail: "/"))
    }

    @Test func answersInOrderAndDropsWithdrawnRequests() async {
        let queue = PermissionQueue()
        let first = request()
        let second = request()
        // Child tasks start in any order, so the second asks only once the first is queued.
        async let firstAnswer = queue.ask(first)
        while queue.requests.isEmpty { await Task.yield() }
        async let secondAnswer = queue.ask(second)
        while queue.requests.count < 2 { await Task.yield() }
        #expect(queue.front?.id == first.id)
        #expect(!queue.isFrontArmed)

        queue.withdraw(first.id)
        #expect(queue.front?.id == second.id)
        queue.answer(second.id, with: .allow)
        queue.answer(second.id, with: .askInTerminal)  // a second answer is ignored

        #expect(await firstAnswer == .askInTerminal)
        #expect(await secondAnswer == .allow)
        #expect(queue.requests.isEmpty)
    }
}

struct LineSocketTests {
    private func socketPath() -> String {
        // sun_path holds 104 bytes, which the per-user temporary directory leaves room for.
        FileManager.default.temporaryDirectory.appendingPathComponent("lotc-\(UUID().uuidString.prefix(8)).sock").path
    }

    @Test func carriesOneLineEachWayAndSpotsAHangUp() throws {
        let path = socketPath()
        let listener = try LineListener(path: path)
        defer { listener.close() }
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let client = try LineConnection.connect(to: path)
        let server = try #require(listener.accept())
        try client.send(LotcRequest(caller: "me", command: .list))
        let request = try server.receive(LotcRequest.self, timeout: 2)
        #expect(request.caller == "me" && request.command == .list)
        try server.send(LotcResponse.lord(group: "united"))
        #expect(try client.receive(LotcResponse.self, timeout: 2) == .lord(group: "united"))

        #expect(!server.hasHungUp(within: 0.1))
        client.close()
        #expect(server.hasHungUp(within: 1))
        server.close()
    }

    @Test func neverTakesOverALiveSocketButReplacesAStaleOne() throws {
        let path = socketPath()
        let first = try LineListener(path: path)
        #expect(throws: LotcSocketError.self) { try LineListener(path: path) }
        first.close()

        FileManager.default.createFile(atPath: path, contents: Data())  // left behind by a crash
        let second = try LineListener(path: path)
        second.close()
    }

    @Test func reportsNobodyListening() {
        #expect(throws: LotcSocketError.self) { try LineConnection.connect(to: FileManager.default.temporaryDirectory.appendingPathComponent("lotc-none.sock").path) }
    }
}
