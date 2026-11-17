import Foundation
import Testing
@testable import LordOfTheClaudes
@testable import LotcKit
@testable import lotc

@MainActor
struct AutoApprovalsTests {
    let home = "/Users/fan"

    private func files() -> (AutoApprovals.Files, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lotc-approvals-\(UUID().uuidString)")
        return (AutoApprovals.Files(settings: dir.appendingPathComponent("auto-approve.json"),
                                    log: dir.appendingPathComponent("auto-approve-log.json")), dir)
    }

    private func input(_ tool: String, _ toolInput: String, cwd: String = "/Users/fan/Projects/united") -> PermissionHookInput {
        PermissionHookInput(json: #"{"session_id":"s","cwd":"\#(cwd)","tool_name":"\#(tool)","tool_input":\#(toolInput)}"#)!
    }

    @Test func aFreshInstallApprovesNothing() {
        let (files, dir) = files()
        defer { try? FileManager.default.removeItem(at: dir) }
        let approvals = AutoApprovals(files: files, home: home)
        #expect(!approvals.settings.isOn)
        #expect(approvals.decide(input("WebSearch", #"{"query":"united"}"#), sessionCwd: nil) == .ask(reason: nil))
        #expect(approvals.log.isEmpty)
    }

    @Test func keepsItsSwitchesAndLogAcrossARestart() throws {
        let (files, dir) = files()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = AutoApprovals(files: files, home: home)
        first.setOn(true)
        first.set(.shellGet, on: false)
        first.exclude("/Users/fan/Private/tax/")
        first.exclude("/srv/secret")
        first.record(.webSearch, summary: "united fixtures", tool: "WebSearch", session: "Fixtures (Home, tab 1)", cwd: "/Users/fan/x")

        let second = AutoApprovals(files: files, home: home)
        #expect(second.settings.isOn)
        #expect(!second.settings.isOn(.shellGet))
        #expect(second.settings.excludedDirectories == ["~/Private/tax", "/srv/secret"])
        #expect(second.log.map(\.summary) == ["united fixtures"])
        #expect(second.log.first?.ruleTitle == "Web search")

        let saved = String(decoding: try Data(contentsOf: files.settings), as: UTF8.self)
        #expect(saved.contains(#""on" : true"#))
    }

    @Test func excludingTakesAbsolutePathsAndTildeOnly() {
        let approvals = AutoApprovals(demo: AutoApproveSettings(), log: [], home: home)
        #expect(!approvals.exclude("relative/dir"))
        #expect(!approvals.exclude(""))
        #expect(approvals.exclude("~/tax"))
        #expect(approvals.exclude("/Users/fan/tax"))  // the same place, kept once
        #expect(approvals.exclude("/Users/fan"))
        #expect(approvals.settings.excludedDirectories == ["~/tax", "~"])
        approvals.include("~/tax")
        #expect(approvals.settings.excludedDirectories == ["~"])
    }

    @Test func decidesWithTheSessionsOwnDirectoryToo() {
        let approvals = AutoApprovals(demo: AutoApproveSettings(isOn: true, excludedDirectories: ["~/Private"]), log: [], home: home)
        let search = input("WebSearch", #"{"query":"united"}"#, cwd: "/tmp")
        #expect(approvals.decide(search, sessionCwd: nil) == .approve(.webSearch, summary: "united"))
        #expect(approvals.decide(search, sessionCwd: "/Users/fan/Private/tax")
                == .ask(reason: "this session works in one of your excluded directories"))
    }

    @Test func countsTheLastHourAndReportsNewestFirst() {
        let approvals = AutoApprovals(demo: AutoApproveSettings(isOn: true), log: [], home: home)
        approvals.record(.webSearch, summary: "old", tool: "WebSearch", session: "s", cwd: "/p", at: Date().addingTimeInterval(-7200))
        approvals.record(.publicFetch, summary: "new", tool: "WebFetch", session: "s", cwd: "/p")
        #expect(approvals.approvedCount(since: Date().addingTimeInterval(-3600)) == 1)
        #expect(approvals.report.log.map(\.summary) == ["new", "old"])
    }
}

@MainActor
struct PrivateSessionTests {
    private func row(_ id: String, cwd: String, goal: String, prompt: String, topic: String? = nil) -> Row {
        let digest = Digest(goal: goal, state: "Under way", at: Date(), topic: topic)
        return Row(id: id, title: "Session \(id)", cwd: cwd, status: "idle", statusSince: nil, lastInteraction: Date(),
                   needsYou: false, prompts: [(Date(), prompt)], ticket: nil, windowId: "w", tab: Int(id),
                   digest: digest, digestHistory: [digest], topic: topic)
    }

    private func store(excluding: [String]) -> Store {
        let approvals = AutoApprovals(demo: AutoApproveSettings(excludedDirectories: excluding), log: [], home: "/Users/fan")
        return Store(demoRows: [row("1", cwd: "/Users/fan/finances/mortgage", goal: "Find the mortgage papers",
                                    prompt: "list the lender's documents", topic: "Mortgage"),
                                row("2", cwd: "/Users/fan/Projects/united", goal: "Plan the coach to Old Trafford",
                                    prompt: "coach times for Saturday", topic: "Fixtures")],
                     groupNames: ["w": "Home"], approvals: approvals)
    }

    @Test func showsByTitleOnly() {
        let store = store(excluding: ["~/finances"])
        let hidden = store.rows.first { $0.id == "1" }!
        #expect(hidden.isPrivate)
        #expect(hidden.digest == nil)
        #expect(hidden.digestHistory.isEmpty)
        #expect(hidden.prompts.isEmpty)
        #expect(hidden.title == "Session 1")
        #expect(SessionText.doing(hidden) == "Private")
        let open = store.rows.first { $0.id == "2" }!
        #expect(!open.isPrivate)
        #expect(open.digest != nil)
    }

    @Test func isLeftOutOfTheOverseersBriefing() {
        let briefing = store(excluding: ["~/finances"]).digestBriefing()
        #expect(!briefing.contains("Session 1"))
        #expect(!briefing.contains("mortgage"))
        #expect(!briefing.contains("Mortgage"))
        #expect(!briefing.contains("lender"))
        #expect(briefing.contains("Session 2"))
        #expect(briefing.hasPrefix("1 session in 1 window"))
        #expect(store(excluding: []).digestBriefing().contains("Session 1"))
    }

    @Test func itsTopicIsNotShownToTheObserver() {
        let store = store(excluding: ["~/finances"])
        #expect(store.topicContext(for: "2").inUse == ["Fixtures"])
        #expect(self.store(excluding: []).topicContext(for: "2").inUse.contains("Mortgage"))
    }

    @Test func itsDigestsAreNotKept() {
        let store = store(excluding: ["~/finances"])
        store.record(Digest(goal: "g", state: "s", at: Date(), topic: "Tax"), for: "1")
        #expect(store.rows.first { $0.id == "1" }?.digest == nil)
        #expect(store.topicsInUse.contains("Mortgage"))
        #expect(!store.topicsInUse.contains("Tax"))
    }

    @Test func excludingADirectoryLaterHidesItsSessions() async {
        let store = store(excluding: [])
        #expect(store.rows.first { $0.id == "1" }?.isPrivate == false)
        store.approvals.exclude("~/finances")
        for _ in 0..<50 where store.rows.first(where: { $0.id == "1" })?.isPrivate != true {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.rows.first { $0.id == "1" }?.isPrivate == true)
        store.approvals.include("~/finances")
        for _ in 0..<50 where store.rows.first(where: { $0.id == "1" })?.isPrivate != false {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.rows.first { $0.id == "1" }?.digest != nil)
    }
}

struct ApprovalsCommandTests {
    @Test func travelsOverTheSocket() throws {
        let entry = ApprovalLogEntry(at: Date(timeIntervalSince1970: 1_700_000_000), session: "s", cwd: "/p", tool: "WebSearch",
                                     summary: "united", rule: "web-search")
        let report = AutoApproveReport(settings: AutoApproveSettings(isOn: true), log: [entry])
        let decoded = try JSONDecoder().decode(LotcResponse.self, from: JSONEncoder().encode(LotcResponse.approvals(report)))
        #expect(decoded == .approvals(report))
        let command = try JSONDecoder().decode(LotcCommand.self, from: JSONEncoder().encode(LotcCommand.approvals))
        #expect(command == .approvals)
    }

    @Test func parses() throws {
        #expect(try Lotc.parse(["approvals"]) == .approvals(status: false, json: false))
        #expect(try Lotc.parse(["approvals", "--json"]) == .approvals(status: false, json: true))
        #expect(try Lotc.parse(["approvals", "status"]) == .approvals(status: true, json: false))
        #expect(try Lotc.parse(["approvals", "status", "--json"]) == .approvals(status: true, json: true))
    }

    @Test(arguments: [["approvals", "on"], ["approvals", "status", "on"], ["approvals", "enable", "web-search"],
                      ["approvals", "--json", "--json"], ["approvals", "--json", "status"], ["approvals", "off"]])
    func hasNoWayToChangeAnything(_ arguments: [String]) {
        #expect(throws: Lotc.UsageError.self) { try Lotc.parse(arguments) }
    }

    @Test func saysInItsHelpThatNoCommandSwitchesARule() {
        #expect(Lotc.usage.contains("No lotc command switches an auto-approve rule on or off"))
    }

    @Test func printsTheStatus() {
        let off = ApprovalsText.status(AutoApproveSettings())
        #expect(off.hasPrefix("Auto-approve: off"))
        #expect(off.contains("Excluded directories: none"))
        let on = ApprovalsText.status(AutoApproveSettings(isOn: true, rules: ["web-search": false], excludedDirectories: ["~/tax"]))
        #expect(on.hasPrefix("Auto-approve: on"))
        #expect(on.contains("off  Web search"))
        #expect(on.contains("on   Fetch a public page"))
        #expect(on.contains("off  Read-only shell commands"))
        #expect(on.contains("  ~/tax"))
    }

    @Test func printsTheLogNewestFirstAsGiven() {
        #expect(ApprovalsText.log([]) == "Nothing has been auto-approved.")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let at = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9, minute: 5))!
        let text = ApprovalsText.log([
            ApprovalLogEntry(at: at, session: "Fixtures (Home, tab 1)", cwd: "/p", tool: "WebSearch",
                             summary: "united fixtures\nDecember", rule: "web-search"),
        ])
        #expect(text == "17/11 09:05  Web search  Fixtures (Home, tab 1)\n    united fixtures December")
    }
}
