import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import LordOfTheClaudes

struct MainKeysTests {
    private func route(_ code: Int, _ characters: String = "", _ modifiers: NSEvent.ModifierFlags = [],
                       focus: MainField?, empty: Bool = true, sidebar: Bool = true, card: Bool = false,
                       composing: Bool = false) -> MainKey {
        MainKeys.route(keyCode: code, modifiers: modifiers, characters: characters,
                       in: .init(focus: focus, composerEmpty: empty, sidebarVisible: sidebar, cardWaiting: card, composing: composing))
    }

    @Test func returnSendsAndShiftReturnStartsALine() {
        #expect(route(kVK_Return, focus: .composer, empty: false) == .send)
        #expect(route(kVK_ANSI_KeypadEnter, focus: .composer, empty: false) == .send)
        #expect(route(kVK_Return, "\r", .shift, focus: .composer, empty: false) == .newLine)
        #expect(route(kVK_Return, focus: .reply(sessionId: "a")) == .sendReply)
        #expect(route(kVK_Return, "\r", .shift, focus: .reply(sessionId: "a")) == .newLine)
        #expect(route(kVK_Return, focus: .composer, empty: false, composing: true) == .passThrough)  // an input method's
    }

    @Test func anEmptyComposerWorksTheList() {
        #expect(route(kVK_DownArrow, focus: .composer) == .move(1))
        #expect(route(kVK_UpArrow, focus: .composer) == .move(-1))
        #expect(route(kVK_RightArrow, focus: .composer) == .showDetail)
        #expect(route(kVK_Return, focus: .composer) == .goToTab)
        // With words in it, the arrows move the cursor.
        #expect(route(kVK_DownArrow, focus: .composer, empty: false) == .passThrough)
        #expect(route(kVK_RightArrow, focus: .composer, empty: false) == .passThrough)
        // With the sidebar out of sight, nothing is picked blind.
        #expect(route(kVK_DownArrow, focus: .composer, sidebar: false) == .passThrough)
        #expect(route(kVK_Return, focus: .composer, sidebar: false) == .nothing)
    }

    @Test func returnOnAnEmptyComposerActsOnAWaitingCard() {
        #expect(route(kVK_Return, focus: .composer, card: true) == .confirmCard)
        #expect(route(kVK_Return, focus: .composer, empty: false, card: true) == .send)  // a new question
        #expect(route(kVK_Return, focus: .proposal) == .confirmCard)
        #expect(route(kVK_Return, "\r", .shift, focus: .proposal) == .newLine)
        #expect(route(kVK_DownArrow, focus: .proposal) == .passThrough)
    }

    @Test func theCommandKeysWorkFromAnywhere() {
        for focus: MainField? in [.composer, .proposal, .filter, .reply(sessionId: "a"), .broadcast(groupId: "g"), nil] {
            #expect(route(kVK_ANSI_L, "l", .command, focus: focus, empty: false) == .focusComposer)
            #expect(route(kVK_ANSI_0, "0", .command, focus: focus, empty: false) == .toggleSidebar)
            #expect(route(kVK_ANSI_F, "f", .command, focus: focus, empty: false) == .focusFilter)
            #expect(route(kVK_ANSI_R, "r", .command, focus: focus, empty: false) == .reply)
            #expect(route(kVK_Escape, focus: focus) == .escape)
        }
    }

    @Test func groupJumpsFromTheComposerFilterAndList() {
        for focus: MainField? in [.composer, .filter, nil] {
            #expect(route(kVK_ANSI_3, "3", .command, focus: focus, empty: false) == .group(3))
            #expect(route(kVK_DownArrow, "", .command, focus: focus, empty: false) == .jumpSection(1))
            #expect(route(kVK_UpArrow, "", .command, focus: focus, empty: false) == .jumpSection(-1))
        }
        // A prompt being written keeps Cmd+Up and Cmd+Down for its cursor.
        #expect(route(kVK_DownArrow, "", .command, focus: .reply(sessionId: "a")) == .passThrough)
    }

    @Test func theFilterAndTheListMoveAndGo() {
        #expect(route(kVK_DownArrow, focus: .filter) == .move(1))
        #expect(route(kVK_Return, focus: .filter) == .goToTab)
        #expect(route(kVK_LeftArrow, focus: .filter) == .passThrough)
        #expect(route(kVK_ANSI_A, "a", focus: .filter) == .passThrough)
        #expect(route(kVK_Return, focus: nil) == .goToTab)
        #expect(route(kVK_RightArrow, focus: nil) == .showDetail)
        #expect(route(kVK_LeftArrow, focus: nil) == .showChat)
    }

    @Test func typingWithTheListFocusedGoesToTheOverseer() {
        #expect(route(kVK_ANSI_W, "w", focus: nil) == .type("w"))
        #expect(route(kVK_ANSI_W, "W", .shift, focus: nil) == .type("W"))
        #expect(route(kVK_F5, "\u{F708}", focus: nil) == .passThrough)
        #expect(route(kVK_ANSI_W, "w", .control, focus: nil) == .passThrough)
        #expect(route(kVK_ANSI_A, "a", focus: .broadcast(groupId: "g")) == .passThrough)
        #expect(route(kVK_Return, focus: .rename(groupId: "g")) == .passThrough)
    }
}

struct WindowPlacementTests {
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 944)
    private let monitor = NSRect(x: 1512, y: 0, width: 2560, height: 1415)

    @Test func opensCentredAtTheDefaultSizeFirstTime() {
        let frame = WindowPlacement.place(saved: nil, screens: [laptop])
        #expect(frame.size == WindowPlacement.defaultSize)
        #expect(frame.midX == laptop.midX && frame.midY == laptop.midY)
    }

    @Test func comesBackWhereItWas() {
        let saved = NSRect(x: 1700, y: 200, width: 1300, height: 900)
        #expect(WindowPlacement.place(saved: saved, screens: [laptop, monitor]) == saved)
    }

    @Test func aWindowLeftOnAScreenThatHasGoneComesBackCentred() {
        let saved = NSRect(x: 1700, y: 200, width: 1300, height: 900)
        let frame = WindowPlacement.place(saved: saved, screens: [laptop])
        #expect(frame.midX == laptop.midX && frame.size == WindowPlacement.defaultSize)
    }

    @Test func isKeptOnItsScreenAndNoSmallerThanTheMinimum() {
        let tooBig = WindowPlacement.place(saved: NSRect(x: 100, y: 50, width: 3000, height: 2000), screens: [laptop])
        #expect(laptop.contains(tooBig))
        let tooSmall = WindowPlacement.place(saved: NSRect(x: 100, y: 50, width: 200, height: 100), screens: [laptop])
        #expect(tooSmall.size == WindowPlacement.minimumSize)
        let hanging = WindowPlacement.place(saved: NSRect(x: 1000, y: 100, width: 1100, height: 760), screens: [laptop])
        #expect(hanging.maxX == laptop.maxX && hanging.width == 1100)
    }

    @Test func remembersTheFrameAcrossLaunches() throws {
        let suite = "lotc-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let frame = NSRect(x: 120, y: 80, width: 980, height: 640)
        WindowPlacement(defaults: defaults).save(frame)
        #expect(WindowPlacement(defaults: defaults).frame(screens: [laptop]) == frame)
        defaults.set("not a rectangle", forKey: WindowPlacement.key)
        #expect(WindowPlacement(defaults: defaults).frame(screens: [laptop]).size == WindowPlacement.defaultSize)
    }
}
