import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import LordOfTheClaudes
@testable import LotcKit

/// Opens a real window and takes focus, so it only runs when asked: LOTC_WINDOW_TESTS=1 ./build.sh test
/// With LOTC_RENDER_DIR set as well, it also saves pictures of the window there to look at.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOTC_WINDOW_TESTS"] == "1"), .serialized)
struct PermissionWindowTests {
    /// Never freed: a Store made for screenshots traps in libdispatch when released (its signal source is never resumed).
    private static let store = Store(demoRows: [])

    private final class Answers {
        var list: [PermissionAnswer] = []
    }

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// Lets both the run loop (windows, Combine) and main-actor tasks have their turn.
    private func spin(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            turnRunLoop()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func turnRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    /// A key press addressed to the panel, handed to what the window's key monitor runs.
    private func press(_ code: Int, _ characters: String, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow,
                       to prompt: PermissionWindow) async {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))!
        _ = prompt.handleKey(event)
        await spin(0.1)
    }

    private static func request(_ tool: String = "Bash", _ input: String = #"{"command":"ls","description":"List"}"#,
                                label: String = "Scout Rashford (united, tab 2)") -> PermissionQueue.Request {
        PermissionQueue.Request(
            input: PermissionHookInput(json: #"{"session_id":"s","cwd":"/Users/mj/united","tool_name":"\#(tool)","tool_input":\#(input)}"#)!,
            origin: .init(sessionId: nil, label: label, detail: "~/Projects/united"))
    }

    @Test func eachKeyAnswersOneQuestionOnlyOnceItHasBeenSeen() async throws {
        let queue = PermissionQueue()
        let window = PermissionWindow(queue: queue, store: Self.store)
        defer { withExtendedLifetime(window) {} }
        let answers = Answers()
        for _ in 0..<4 {
            Task { answers.list.append(await queue.ask(Self.request())) }
        }
        await spin(0.3)
        let panel = try #require(NSApp.windows.first { $0 is PermissionPanel })
        #expect(panel.isVisible)

        await press(kVK_Return, "\r", .command, in: panel, to: window)
        #expect(answers.list.isEmpty, "a key already on its way must not answer a question nobody has read")

        await spin(PermissionQueue.armingDelay)
        await press(kVK_Return, "\r", in: panel, to: window)
        #expect(answers.list.isEmpty, "plain Return must never approve")
        await press(kVK_Return, "\r", .command, in: panel, to: window)
        #expect(answers.list == [.allow])

        await spin(PermissionQueue.armingDelay)
        await press(kVK_ANSI_D, "d", .command, in: panel, to: window)
        #expect(answers.list.last == .deny(message: PermissionWindow.plainDenial, interrupt: true))

        await spin(PermissionQueue.armingDelay)
        window.instead = "Use the test database instead."
        window.submitInstead()
        await spin(0.1)
        #expect(answers.list.last == .deny(message: "Use the test database instead.", interrupt: false))
        await spin(0.1)
        #expect(window.instead.isEmpty, "the next question starts with an empty box")

        await spin(PermissionQueue.armingDelay)
        await press(kVK_Escape, "\u{1b}", in: panel, to: window)
        #expect(answers.list.last == .askInTerminal)
        await spin(0.2)
        #expect(!panel.isVisible)
        #expect(answers.list.count == 4)
    }

    @Test func savesPicturesWhenAskedTo() async throws {
        guard let dir = ProcessInfo.processInfo.environment["LOTC_RENDER_DIR"] else { return }
        let edit = #"{"file_path":"/Users/mj/united/Sources/Squad.swift","old_string":"let captain = \"Maguire\"","new_string":"let captain = \"Fernandes\"\nlet viceCaptain = \"Maguire\"","replace_all":false}"#
        let write = #"{"file_path":"/Users/mj/united/NOTES.md","content":"\#((1...60).map { "Line \($0) of the match report" }.joined(separator: "\\n"))"}"#
        let fetch = #"{"url":"https://www.manutd.com/en/fixtures","prompt":"List the next three home fixtures"}"#
        let shots: [(String, PermissionQueue.Request, Int)] = [
            ("permission-bash", Self.request(), 1),
            ("permission-edit", Self.request("Edit", edit), 3),
            ("permission-write", Self.request("Write", write), 1),
            ("permission-other", Self.request("WebFetch", fetch, label: "~/Projects/united · subagent Explore"), 2),
        ]
        for (name, request, count) in shots {
            for dark in [false, true] {
                let queue = PermissionQueue()
                Task { _ = await queue.ask(request) }
                for _ in 1..<count { Task { _ = await queue.ask(Self.request()) } }
                await spin(0.1)
                let prompt = PermissionWindow(queue: PermissionQueue(), store: Self.store)
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: PermissionView(queue: queue, prompt: prompt)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = appearance
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = appearance
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
                window.orderFrontRegardless()
                await spin(PermissionQueue.armingDelay + 0.3)
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let file = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: file)
                window.orderOut(nil)
                withExtendedLifetime(prompt) {}
            }
        }
    }
}
