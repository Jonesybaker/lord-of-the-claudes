import Foundation
import LotcKit

enum Lotc {
    static let usage = """
        lotc: work with the other Claude Code sessions in your Ghostty window, through Lord of the Claudes.

        Usage:
          lotc list [--json]                    the sessions in this window: tab, status, waiting for you, lord, title
          lotc send <tab> <prompt>              type a prompt into another tab and submit it
          lotc broadcast <prompt>               send a prompt to every other tab in this window
          lotc wait <tab> [--timeout <seconds>] wait until that tab has finished what it was last sent, then print its answer
          lotc last <tab>                       print that tab's last answer now
          lotc lord                             make this session the lord of its window
          lotc hooks install|uninstall|status   answer Claude Code's permission prompts in Lord of the Claudes
          lotc permission                       the permission hook itself; Claude Code runs it

        <tab> is a tab number from lotc list, or part of one session's title.
        A <prompt> of "-" is read from stdin.
        wait gives up after \(Int(defaultWaitTimeout)) seconds unless told otherwise, inside Claude Code's two-minute
        Bash limit; run it again to keep waiting.
        Run lotc from a Claude Code session in Ghostty, with Lord of the Claudes running.
        Exit status: 0 done, 1 could not be done, 2 the command line is wrong.
        """

    static let defaultWaitTimeout: TimeInterval = 110

    enum Invocation: Equatable {
        case help
        case list(json: Bool)
        case send(tab: String, prompt: String)
        case broadcast(prompt: String)
        case wait(tab: String, timeout: TimeInterval)
        case last(tab: String)
        case lord
        case hooks(HookCommand.Action)
        case permission
    }

    struct UsageError: Error, Equatable {
        let message: String
    }

    static func main(_ arguments: [String]) -> Int32 {
        let invocation: Invocation
        do {
            invocation = try parse(arguments)
        } catch {
            let message = (error as? UsageError)?.message ?? "\(error)"
            FileHandle.standardError.write(Data("lotc: \(message)\n".utf8))
            return 2
        }
        switch invocation {
        case .help:
            print(usage)
            return 0
        case .permission:
            return PermissionHookCommand.run()
        case .hooks(let action):
            return HookCommand.run(action)
        default:
            return talkToApp(invocation)
        }
    }

    static func parse(_ arguments: [String]) throws -> Invocation {
        guard let command = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "-h", "--help", "help":
            return .help
        case "list":
            guard rest.allSatisfy({ $0 == "--json" }) else { throw UsageError(message: "list takes only --json") }
            return .list(json: !rest.isEmpty)
        case "send":
            guard rest.count >= 2 else { throw UsageError(message: #"send needs a tab and a prompt: lotc send 2 "run the tests""#) }
            return .send(tab: rest[0], prompt: rest.dropFirst().joined(separator: " "))
        case "broadcast":
            guard !rest.isEmpty else { throw UsageError(message: #"broadcast needs a prompt: lotc broadcast "pull main""#) }
            return .broadcast(prompt: rest.joined(separator: " "))
        case "wait":
            return try parseWait(rest)
        case "last":
            guard rest.count == 1 else { throw UsageError(message: "last needs one tab: lotc last 2") }
            return .last(tab: rest[0])
        case "lord":
            guard rest.isEmpty else { throw UsageError(message: "lord takes no arguments") }
            return .lord
        case "hooks":
            guard rest.count == 1, let action = HookCommand.Action(rawValue: rest[0]) else {
                throw UsageError(message: "hooks needs one of install, uninstall or status")
            }
            return .hooks(action)
        case "permission":
            return .permission
        default:
            throw UsageError(message: "there is no \"\(command)\" command. lotc --help lists them.")
        }
    }

    private static func parseWait(_ rest: [String]) throws -> Invocation {
        var tab: String?
        var timeout = defaultWaitTimeout
        var index = 0
        while index < rest.count {
            let argument = rest[index]
            if argument == "--timeout" || argument.hasPrefix("--timeout=") {
                let value = argument == "--timeout"
                    ? (index + 1 < rest.count ? rest[index + 1] : "")
                    : String(argument.dropFirst("--timeout=".count))
                guard let seconds = TimeInterval(value), seconds >= 0 else {
                    throw UsageError(message: "--timeout needs a number of seconds")
                }
                timeout = seconds
                index += argument == "--timeout" ? 2 : 1
            } else if tab == nil {
                tab = argument
                index += 1
            } else {
                throw UsageError(message: "wait takes one tab: lotc wait 2 --timeout 300")
            }
        }
        guard let tab else { throw UsageError(message: "wait needs a tab: lotc wait 2") }
        return .wait(tab: tab, timeout: timeout)
    }

    // MARK: Talking to the app

    private static func talkToApp(_ invocation: Invocation) -> Int32 {
        let claudeHome = ClaudeHome.url
        guard let caller = Caller.sessionId(claudeHome: claudeHome) else {
            return fail("run lotc from a Claude Code session. None of its parent processes is in \(claudeHome.path)/sessions.")
        }

        let command: LotcCommand
        let timeout: TimeInterval
        switch invocation {
        case .list:
            (command, timeout) = (.list, 15)
        case .send(let tab, let prompt):
            (command, timeout) = (.send(tab: tab, prompt: readPrompt(prompt)), 30)
        case .broadcast(let prompt):
            (command, timeout) = (.broadcast(prompt: readPrompt(prompt)), 120)
        case .wait(let tab, let seconds):
            (command, timeout) = (.wait(tab: tab, timeout: seconds), seconds + 30)
        case .last(let tab):
            (command, timeout) = (.last(tab: tab), 30)
        case .lord:
            (command, timeout) = (.lord, 15)
        case .help, .hooks, .permission:
            return 2
        }

        let response: LotcResponse
        do {
            let connection = try LineConnection.connect(to: LotcSocket.path)
            defer { connection.close() }
            try connection.send(LotcRequest(caller: caller, command: command))
            response = try connection.receive(LotcResponse.self, timeout: timeout)
        } catch LotcSocketError.nobodyListening(let path) {
            return fail("Lord of the Claudes is not running, or is too old for lotc: nothing is listening on \(path).")
        } catch {
            return fail("lost touch with Lord of the Claudes: \(error)")
        }
        return show(response, json: invocation == .list(json: true))
    }

    private static func readPrompt(_ prompt: String) -> String {
        guard prompt == "-" else { return prompt }
        let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        return text.trimmingCharacters(in: .newlines)
    }

    private static func show(_ response: LotcResponse, json: Bool) -> Int32 {
        switch response {
        case .failure(let message):
            return fail(message)
        case .window(let listing):
            print(json ? encoded(listing) : table(listing))
            return 0
        case .sent(let reached, let missed):
            for session in reached { print("Sent to tab \(session.tab): \(session.title)") }
            for session in missed { warn("Could not type into tab \(session.tab): \(session.title)") }
            return missed.isEmpty ? 0 : 1
        case .message(let message):
            if message.text.isEmpty {
                warn("Tab \(message.session.tab) (\(message.session.title)) has not said anything yet.")
            } else {
                print(message.text)
            }
            return 0
        case .lord(let group):
            print("This session is now the lord of \(group).")
            return 0
        case .permission:
            return fail("Lord of the Claudes sent an answer meant for the permission hook.")
        }
    }

    static func table(_ listing: WindowListing) -> String {
        let header = ["TAB", "STATUS", "WAITING", "LORD", "TITLE"]
        let rows = listing.sessions.map { session in
            [String(session.tab), statusWord(session), session.waitingForYou ? "yes" : "", session.isLord ? "yes" : "",
             session.title + (session.isCaller ? "  (you)" : "")]
        }
        let widths = (0..<4).map { column in ([header] + rows).map { $0[column].count }.max() ?? 0 }
        let lines = ([header] + rows).map { cells in
            (0..<4).map { cells[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ")
                + "  " + cells[4]
        }
        let count = listing.sessions.count
        return (["\(listing.group): \(count) session\(count == 1 ? "" : "s")"] + lines).joined(separator: "\n")
    }

    private static func statusWord(_ session: SessionSummary) -> String {
        session.isWorking ? "working" : session.status
    }

    private static func encoded(_ listing: WindowListing) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(listing)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    @discardableResult
    static func fail(_ message: String) -> Int32 {
        warn("lotc: " + message)
        return 1
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
