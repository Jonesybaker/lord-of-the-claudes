import AppKit
import Foundation

struct GhosttyTerminal {
    let id: String
    /// The Ghostty window this terminal's tab is in.
    let windowId: String
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
        // One record per window: its id, then the ids, titles and directories of its terminals.
        // Separators are ASCII control characters, which never appear in a title or a path.
        let script = """
        set US to (character id 31)
        set RS to (character id 30)
        set GS to (character id 29)
        set out to ""
        set f to ""
        tell application "Ghostty"
            repeat with w in windows
                set a to id of terminals of tabs of w
                set b to name of terminals of tabs of w
                set c to working directory of terminals of tabs of w
                set AppleScript's text item delimiters to US
                set out to out & (id of w) & RS & (a as text) & RS & (b as text) & RS & (c as text) & GS
            end repeat
            if frontmost then
                try
                    set f to id of focused terminal of selected tab of front window
                end try
            end if
        end tell
        return out & linefeed & f
        """
        guard let out = run(script), let split = out.lastIndex(of: "\n") else { return nil }
        var terminals: [GhosttyTerminal] = []
        for window in out[..<split].split(separator: "\u{1D}") {
            let fields = window.split(separator: "\u{1E}", omittingEmptySubsequences: false)
                .map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) }
            guard fields.count == 4, let windowId = fields[0].first,
                  fields[1].count == fields[2].count, fields[1].count == fields[3].count
            else { return nil }
            for i in fields[1].indices where !fields[1][i].isEmpty {
                terminals.append(GhosttyTerminal(id: fields[1][i], windowId: windowId, title: fields[2][i], cwd: fields[3][i]))
            }
        }
        let focused = String(out[out.index(after: split)...])
        return State(terminals: terminals, focusedId: focused.isEmpty ? nil : focused)
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

    /// Types a prompt into a terminal and submits it. Claude Code queues it if it is busy.
    static func send(text: String, toTerminal terminalId: String) -> Bool {
        guard app != nil else { return false }
        return run("""
        tell application "Ghostty"
            set t to first terminal whose id is "\(escape(terminalId))"
            input text "\(escape(text))" to t
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
