import Foundation
import Testing
@testable import LotcKit
@testable import lotc

struct HookSettingsTests {
    let lotc = "/opt/homebrew/bin/lotc"
    var permission: HookSettings.Installed { .init(hook: .permission, command: lotc + " permission", timeout: 600) }
    var observe: HookSettings.Installed { .init(hook: .observe, command: lotc + " observe", timeout: nil) }

    @Test func installsBothHooksIntoEmptySettingsInTheDocumentedShape() throws {
        let installed = HookSettings.installing(lotcAt: lotc, into: .object([]))
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
                ],
                "Stop": [
                  {
                    "hooks": [
                      {
                        "type": "command",
                        "command": "/opt/homebrew/bin/lotc observe",
                        "async": true
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
        let after = HookSettings.installing(lotcAt: lotc, into: before)
        #expect(after.members?.map(\.key) == ["model", "hooks", "theme"])
        #expect(after["hooks"]?.members?.map(\.key) == ["Stop", "PermissionRequest"])
        for event in ["Stop", "PermissionRequest"] {
            let groups = after["hooks"]?[event]?.array ?? []
            #expect(groups.count == 2)
            #expect(groups.first == before["hooks"]?[event]?.array?.first)
        }
        #expect(HookSettings.installed(in: after) == [permission, observe])
    }

    @Test func installAddsOnlyTheHookThatIsMissing() throws {
        // As an earlier lotc left it: the permission hook alone, which must stay exactly as it was.
        let before = try JSONValue(parsing: """
            {"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[
              {"type":"command","command":"/opt/homebrew/bin/lotc permission","timeout":600},
              {"type":"command","command":"notify.sh"}]}]}}
            """)
        let after = HookSettings.installing(lotcAt: lotc, into: before)
        #expect(after["hooks"]?["PermissionRequest"] == before["hooks"]?["PermissionRequest"])
        #expect(HookSettings.installed(in: after) == [permission, observe])
    }

    @Test func installTwiceChangesNothing() {
        let once = HookSettings.installing(lotcAt: lotc, into: .object([]))
        #expect(HookSettings.installing(lotcAt: lotc, into: once) == once)
    }

    @Test func installReplacesHooksLeftByALotcElsewhere() throws {
        let stale = HookSettings.installing(lotcAt: "/old/place/lotc", into: .object([]))
        let fresh = HookSettings.installing(lotcAt: lotc, into: stale)
        #expect(HookSettings.installed(in: fresh) == [permission, observe])
    }

    @Test func uninstallRemovesBothAndOnlyLotcsAndTidiesEmptyContainers() throws {
        let shared = try JSONValue(parsing: """
            {"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[
              {"type":"command","command":"/opt/homebrew/bin/lotc permission"},
              {"type":"command","command":"notify.sh"}]}],
             "Stop":[{"hooks":[{"type":"command","command":"/opt/homebrew/bin/lotc observe","async":true}]},
                     {"hooks":[{"type":"command","command":"say done"}]}]}}
            """)
        #expect(HookSettings.uninstalling(from: shared) == (try JSONValue(parsing: """
            {"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"notify.sh"}]}],
             "Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}
            """)))

        let onlyOurs = HookSettings.installing(lotcAt: lotc, into: try JSONValue(parsing: #"{"model":"opus"}"#))
        #expect(HookSettings.uninstalling(from: onlyOurs) == (try JSONValue(parsing: #"{"model":"opus"}"#)))
    }

    @Test func uninstallWithNothingInstalledChangesNothing() throws {
        let settings = try JSONValue(parsing: #"{"hooks":{"Stop":[]}}"#)
        #expect(HookSettings.uninstalling(from: settings) == settings)
    }

    @Test func statusNamesEachHookInstalledOrNot() throws {
        let neither = HookSettings.uninstalling(from: HookSettings.installing(lotcAt: "/nowhere/lotc", into: .object([])))
        #expect(HookCommand.status(of: neither, in: "~/.claude/settings.json") == """
            The permission hook is not installed in ~/.claude/settings.json.
            The observer hook is not installed in ~/.claude/settings.json.
            """)
        let both = HookSettings.installing(lotcAt: "/nowhere/lotc", into: .object([]))
        #expect(HookCommand.status(of: both, in: "~/s.json") == """
            The permission hook is installed in ~/s.json: /nowhere/lotc permission (timeout 600s)
              but /nowhere/lotc does not exist; run lotc hooks install again.
            The observer hook is installed in ~/s.json: /nowhere/lotc observe
              but /nowhere/lotc does not exist; run lotc hooks install again.
            """)
    }

    @Test func installStatusAndUninstallRoundTripAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lotc-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        let original = "{\n  \"model\": \"opus\"\n}\n"
        try Data(original.utf8).write(to: url)
        let fake = dir.appendingPathComponent("lotc").path

        #expect(HookCommand.run(.status, settingsURL: url, lotcPath: fake) == 1)
        #expect(HookCommand.run(.install, settingsURL: url, lotcPath: fake) == 0)
        let installed = try SettingsFile(url: url).read()
        #expect(Set(HookSettings.installed(in: installed).map(\.hook)) == [.permission, .observe])
        #expect(HookCommand.run(.install, settingsURL: url, lotcPath: fake) == 0)
        #expect(try SettingsFile(url: url).read() == installed)
        #expect(HookCommand.run(.status, settingsURL: url, lotcPath: fake) == 0)
        #expect(HookCommand.run(.uninstall, settingsURL: url, lotcPath: fake) == 0)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test func quotesAPathWithSpacesForTheShellAndReadsItBack() {
        let path = "/Applications/Lord of the Claudes.app/Contents/MacOS/lotc"
        for hook in LotcHook.allCases {
            let command = HookSettings.command(forExecutable: path, hook)
            #expect(command == "'/Applications/Lord of the Claudes.app/Contents/MacOS/lotc' \(hook.rawValue)")
            #expect(HookSettings.lotcPath(inCommand: command, hook) == path)
        }
        #expect(HookSettings.command(forExecutable: "/opt/homebrew/bin/lotc", .observe) == "/opt/homebrew/bin/lotc observe")
    }

    @Test(arguments: ["notify.sh", "lotc", "/bin/other permission", "/x/lotc list", "/x/notlotc permission",
                      "/x/lotc observe"])
    func doesNotMistakeOtherHooksForLotcsPermissionHook(_ command: String) {
        #expect(HookSettings.lotcPath(inCommand: command, .permission) == nil)
    }

    @Test func tellsItsTwoHooksApart() {
        #expect(HookSettings.lotcPath(inCommand: "/x/lotc observe", .observe) == "/x/lotc")
        #expect(HookSettings.lotcPath(inCommand: "/x/lotc permission", .observe) == nil)
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
        let backup = try file.write(HookSettings.installing(lotcAt: "/opt/homebrew/bin/lotc", into: try file.read()))

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: backup!, encoding: .utf8) == "{\n  \"model\": \"opus\"\n}\n")
        #expect(HookSettings.installed(in: try file.read()).count == 2)
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
