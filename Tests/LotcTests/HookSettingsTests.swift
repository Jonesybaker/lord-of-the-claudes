import Foundation
import Testing
@testable import LotcKit
@testable import lotc

struct HookSettingsTests {
    let command = "/opt/homebrew/bin/lotc permission"

    @Test func installsIntoEmptySettingsInTheDocumentedShape() throws {
        let installed = HookSettings.installing(command, into: .object([]))
        #expect(installed.formatted() == """
            {
              "hooks": {
                "PermissionRequest": [
                  {
                    "matcher": "*",
                    "hooks": [
                      {
                        "type": "command",
                        "command": "/opt/homebrew/bin/lotc permission",
                        "timeout": 600
                      }
                    ]
                  }
                ]
              }
            }
            """)
    }

    @Test func installLeavesEverythingElseWhereItWas() throws {
        let before = try JSONValue(parsing: """
            {"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"stop.sh"}]}],
             "PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard.sh"}]}]},"theme":"dark"}
            """)
        let after = HookSettings.installing(command, into: before)
        #expect(after.members?.map(\.key) == ["model", "hooks", "theme"])
        #expect(after["hooks"]?.members?.map(\.key) == ["Stop", "PermissionRequest"])
        #expect(after["hooks"]?["Stop"] == before["hooks"]?["Stop"])
        let groups = after["hooks"]?["PermissionRequest"]?.array ?? []
        #expect(groups.count == 2)
        #expect(groups.first == before["hooks"]?["PermissionRequest"]?.array?.first)
        #expect(HookSettings.installed(in: after) == [.init(command: command, timeout: 600)])
    }

    @Test func installTwiceChangesNothing() {
        let once = HookSettings.installing(command, into: .object([]))
        #expect(HookSettings.installing(command, into: once) == once)
    }

    @Test func installReplacesAHookLeftByALotcElsewhere() throws {
        let stale = HookSettings.installing("/old/place/lotc permission", into: .object([]))
        let fresh = HookSettings.installing(command, into: stale)
        #expect(HookSettings.installed(in: fresh) == [.init(command: command, timeout: 600)])
    }

    @Test func uninstallRemovesOnlyLotcAndTidiesEmptyContainers() throws {
        let shared = try JSONValue(parsing: """
            {"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[
              {"type":"command","command":"/opt/homebrew/bin/lotc permission"},
              {"type":"command","command":"notify.sh"}]}]}}
            """)
        #expect(HookSettings.uninstalling(from: shared) == (try JSONValue(parsing: """
            {"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"notify.sh"}]}]}}
            """)))

        let onlyOurs = HookSettings.installing(command, into: try JSONValue(parsing: #"{"model":"opus"}"#))
        #expect(HookSettings.uninstalling(from: onlyOurs) == (try JSONValue(parsing: #"{"model":"opus"}"#)))
    }

    @Test func uninstallWithNothingInstalledChangesNothing() throws {
        let settings = try JSONValue(parsing: #"{"hooks":{"Stop":[]}}"#)
        #expect(HookSettings.uninstalling(from: settings) == settings)
    }

    @Test func quotesAPathWithSpacesForTheShellAndReadsItBack() {
        let path = "/Applications/Lord of the Claudes.app/Contents/MacOS/lotc"
        let command = HookSettings.command(forExecutable: path)
        #expect(command == "'/Applications/Lord of the Claudes.app/Contents/MacOS/lotc' permission")
        #expect(HookSettings.lotcPath(inCommand: command) == path)
        #expect(HookSettings.command(forExecutable: "/opt/homebrew/bin/lotc") == "/opt/homebrew/bin/lotc permission")
    }

    @Test(arguments: ["notify.sh", "lotc", "/bin/other permission", "/x/lotc list", "/x/notlotc permission"])
    func doesNotMistakeOtherHooksForLotc(_ command: String) {
        #expect(HookSettings.lotcPath(inCommand: command) == nil)
    }

    @Test func writesThroughASymlinkKeepingABackupAndThePermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lotc-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dotfiles = dir.appendingPathComponent("dotfiles")
        let claude = dir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("settings.json")
        try Data("{\n  \"model\": \"opus\"\n}\n".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = claude.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let file = SettingsFile(url: link)
        let backup = try file.write(HookSettings.installing(command, into: try file.read()))

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: backup!, encoding: .utf8) == "{\n  \"model\": \"opus\"\n}\n")
        #expect(HookSettings.installed(in: try file.read()).count == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
}

struct SettingsBackupTests {
    @Test func twoWritesInTheSameSecondKeepBothBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lotc-backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        try Data("{\n  \"model\": \"opus\"\n}\n".utf8).write(to: url)

        let file = SettingsFile(url: url)
        let first = try #require(try file.write(.object([JSONMember("model", .string("sonnet"))])))
        let second = try #require(try file.write(.object([JSONMember("model", .string("haiku"))])))
        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "{\n  \"model\": \"opus\"\n}\n")
        #expect(try String(contentsOf: second, encoding: .utf8) == "{\n  \"model\": \"sonnet\"\n}\n")
    }
}

struct AnsweredElsewhereTests {
    private func call(_ id: String, _ command: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"description":"d","command":"\#(command)"}}]}}"# + "\n"
    }

    private func result(_ id: String) -> String {
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}}"# + "\n"
    }

    @Test func seesOnlyAResultForTheAskedCallWrittenAfterTheHookStarted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lotc-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        // The same command ran and was answered once before; the second call is the one being asked about.
        try Data((call("old", "touch x") + result("old") + call("new", "touch x")).utf8).write(to: url)
        let hookInput = try JSONValue(parsing: """
            {"transcript_path":"\(url.path)","tool_name":"Bash","tool_input":{"command":"touch x","description":"d"}}
            """)
        let watch = try #require(AnsweredElsewhere(hookInput: hookInput))
        #expect(!watch.hasHappened())

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((call("other", "ls") + result("other")).utf8))
        #expect(!watch.hasHappened())
        let answer = result("new")
        try handle.write(contentsOf: Data(answer.dropLast(10).utf8))  // still being written
        #expect(!watch.hasHappened())
        try handle.write(contentsOf: Data(answer.suffix(10).utf8))
        try handle.close()
        #expect(watch.hasHappened())
    }

    @Test func comparesToolInputsAsJSONValues() throws {
        let a = try JSONValue(parsing: #"{"command":"ls","timeout":1,"flags":[1,2]}"#)
        #expect(a.isEquivalent(to: try JSONValue(parsing: #"{"flags":[1,2],"timeout":1.0,"command":"ls"}"#)))
        #expect(!a.isEquivalent(to: try JSONValue(parsing: #"{"command":"ls","timeout":1,"flags":[2,1]}"#)))
        #expect(!a.isEquivalent(to: try JSONValue(parsing: #"{"command":"ls","timeout":1}"#)))
    }
}
