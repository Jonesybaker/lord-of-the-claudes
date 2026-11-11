import AppKit
import Foundation

struct GhosttyTerminal {
    let id: String
    let title: String
    let cwd: String

    /// Claude Code titles its tab "<status glyph> <session title>"; a plain shell prompt starts with ASCII.
    var looksLikeClaude: Bool {
        guard let first = title.unicodeScalars.first else { return false }
        return !first.isASCII && title.dropFirst().first == " "
    }

    var sessionTitle: String { looksLikeClaude ? String(title.dropFirst(2)) : title }
}

/// Drives Ghostty through its AppleScript dictionary (Ghostty 1.3+).
/// Every call blocks on osascript, so keep them off the main thread.
enum Ghostty {
    static let bundleId = "com.mitchellh.ghostty"

    /// Checked before every script: `tell application` would otherwise launch Ghostty.
    static var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
    }

    struct State {
        /// In window then tab order, which is the order Ghostty restores them in.
        var terminals: [GhosttyTerminal]
        /// The terminal the user is looking at; nil when Ghostty is not the front app.
        var focusedId: String?
    }

    static func state() -> State? {
        guard app != nil else { return nil }
        let script = """
        tell application "Ghostty"
            set a to id of terminals of tabs of windows
            set b to name of terminals of tabs of windows
            set c to working directory of terminals of tabs of windows
            set f to ""
            if frontmost then
                try
                    set f to id of focused terminal of selected tab of front window
                end try
            end if
        end tell
        set AppleScript's text item delimiters to (character id 31)
        return (a as text) & linefeed & (b as text) & linefeed & (c as text) & linefeed & f
        """
        guard let out = run(script) else { return nil }
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 4 else { return nil }
        let lists = lines.prefix(3).map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) }
        guard lists[0].count == lists[1].count, lists[0].count == lists[2].count else { return nil }
        let terminals = lists[0].indices.compactMap { i in
            lists[0][i].isEmpty ? nil : GhosttyTerminal(id: lists[0][i], title: lists[1][i], cwd: lists[2][i])
        }
        return State(terminals: terminals, focusedId: lines[3].isEmpty ? nil : String(lines[3]))
    }

    static func terminals() -> [GhosttyTerminal]? { state()?.terminals }

    static func close(terminalId: String) {
        guard app != nil else { return }
        _ = run("""
        tell application "Ghostty" to close (first terminal whose id is "\(escape(terminalId))")
        """)
    }

    static func focus(terminalId: String) {
        guard app != nil else { return }
        _ = run("""
        tell application "Ghostty"
            focus (first terminal whose id is "\(escape(terminalId))")
            activate
        end tell
        """)
    }

    /// Types the resume command into an existing terminal that is sitting at a shell prompt.
    static func resume(sessionId: String, inTerminal terminalId: String) -> Bool {
        guard app != nil, UUID(uuidString: sessionId) != nil else { return false }
        return run("""
        tell application "Ghostty"
            set t to first terminal whose id is "\(escape(terminalId))"
            input text "claude --resume \(sessionId)" to t
            delay 0.3
            send key "enter" to t
        end tell
        """) != nil
    }

    static func resumeInNewTab(sessionId: String, cwd: String) -> Bool {
        guard app != nil, UUID(uuidString: sessionId) != nil else { return false }
        return run("""
        tell application "Ghostty"
            set cfg to new surface configuration
            set initial working directory of cfg to "\(escape(cwd))"
            set initial input of cfg to "claude --resume \(sessionId)" & linefeed
            if (count of windows) > 0 then
                new tab in front window with configuration cfg
            else
                new window with configuration cfg
            end if
        end tell
        """) != nil
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var out = String(decoding: data, as: UTF8.self)
        if out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}
