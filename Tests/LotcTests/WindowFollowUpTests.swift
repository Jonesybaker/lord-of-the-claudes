import Foundation
import Testing
@testable import LordOfTheClaudes
@testable import LotcKit

/// The window model on a made-up store: two open sessions and a private one in one window.
@MainActor
struct WindowFollowUpTests {
    private let secrets = ["mortgage", "lender", "finances", "statement"]

    private func setUp() -> (WindowModel, FakeRunner, FakeReader, Box) {
        let now = Date()
        func row(_ id: String, _ title: String, _ cwd: String, tab: Int) -> Row {
            Row(id: id, title: title, cwd: cwd, status: "idle", statusSince: now, lastInteraction: now, needsYou: false,
                prompts: [(now, "a prompt")], ticket: nil, windowId: "w", tab: tab, topic: "Matchday")
        }
        let approvals = AutoApprovals(demo: AutoApproveSettings(excludedDirectories: ["~/finances"]), log: [], home: "/Users/fan")
        let store = Store(demoRows: [row("kit", "Price the away kit", "/Users/fan/Projects/shop", tab: 1),
                                     row("scout", "Scout Rashford", "/Users/fan/Projects/united", tab: 2),
                                     row("mortgage", "Reconcile the mortgage statements", "/Users/fan/finances/mortgage", tab: 3)],
                          groupNames: ["w": "Matchday"], approvals: approvals)
        let runner = FakeRunner([.success("Both pulled. The kit one has 3 new commits; the scout one had none."),
                                 .success("Pulled."), .success("Pulled.")])
        let reader = FakeReader()
        let chat = OverseerChat(runner: runner, file: nil, settingsFile: nil, reader: reader, timing: fastTiming)
        let typed = Box()
        let model = WindowModel(store: store, chat: chat, defaults: nil, reader: reader, poll: .milliseconds(5),
                                typist: { text, _, id in typed.sent.append((text, id)); return true })
        return (model, runner, reader, typed)
    }

    @MainActor final class Box { var sent: [(text: String, id: String)] = [] }

    @Test(arguments: ["kit", "mortgage"])
    func aReplyShowsItsAnswerInPlaceWithNoModel(_ id: String) async throws {
        let (model, runner, reader, typed) = setUp()
        let row = try #require(model.store.rows.first { $0.id == id })
        #expect(row.isPrivate == (id == "mortgage"))
        reader.busy(id)
        reader.transcripts[id] = [Exchange(prompt: "earlier", answer: "An earlier answer.")]
        model.drafts[id] = "check the totals"
        model.sendReply(to: row)
        #expect(await eventually { model.threads[id]?.waiting == true })
        #expect(typed.sent.map(\.text) == ["check the totals"])

        reader.answers(id, "The totals match to the penny.", prompt: "check the totals")
        #expect(await eventually { model.threads[id]?.waiting == false })
        let thread = try #require(model.threads[id])
        #expect(thread.exchanges.map(\.answer) == ["An earlier answer.", "The totals match to the penny."])
        #expect(thread.stoppedFor == nil)
        #expect(runner.requests.isEmpty)
        #expect(model.chat.conversation.messages.isEmpty && model.chat.watching.isEmpty)
    }

    @Test func aReplyThatStopsForAPermissionPromptSaysSo() async throws {
        let (model, _, reader, _) = setUp()
        let row = try #require(model.store.rows.first { $0.id == "kit" })
        reader.busy("kit")
        model.drafts["kit"] = "run the tests"
        model.sendReply(to: row)
        reader.waits("kit", for: "permission prompt", "Running them now.")
        #expect(await eventually { model.threads["kit"]?.waiting == false })
        #expect(model.threads["kit"]?.stoppedFor == "It is waiting for you: permission prompt.")
    }

    @Test func aBroadcastTellsTheOverseerOnlyThePublicAnswers() async throws {
        let (model, runner, reader, typed) = setUp()
        model.grouping = .window
        let group = try #require(model.groups.first { $0.kind == .window("w") })
        #expect(Set(group.all.map(\.id)) == ["kit", "scout", "mortgage"])
        for id in ["kit", "scout", "mortgage"] { reader.busy(id) }
        model.broadcast = BroadcastDraft(groupId: group.id, text: "pull main", confirming: true, recipients: group.all.map(\.id))
        model.submitBroadcast(to: group)
        #expect(await eventually { model.chat.watching.count == 3 })
        #expect(Set(typed.sent.map(\.id)) == ["kit", "scout", "mortgage"])

        reader.answers("kit", "Pulled; 3 new commits.")
        reader.answers("scout", "Pulled; nothing new.")
        reader.answers("mortgage", "Pulled. The lender's statement is reconciled.")
        #expect(await eventually { runner.requests.count == 1 })
        await model.chat.settle()
        let report = runner.requests[0].message
        #expect(report.contains("Pulled; 3 new commits.") && report.contains("Pulled; nothing new."))
        #expect(report.contains("every session in Matchday"))
        #expect(secrets.filter { report.lowercased().contains($0) } == [])
        #expect(!reader.read.contains("mortgage"))

        let messages = model.chat.conversation.messages
        let privateNote = try #require(messages.first { $0.text.hasPrefix("Reconcile the mortgage statements has replied.") })
        #expect(privateNote.isPrivate == true && privateNote.goTo == "mortgage")
        #expect(messages.filter { $0.isPrivate != true }.allSatisfy { m in !secrets.contains { m.text.lowercased().contains($0) } })
        let sentNote = try #require(messages.first { $0.text.hasPrefix("Sent from the megaphone on Matchday to ") })
        #expect(sentNote.text.contains("Matchday, tab 1 (Price the away kit)") && sentNote.text.contains("1 private session"))
        #expect(sentNote.text.hasSuffix(": pull main") && sentNote.isPrivate == nil)
    }

    @Test func aReportOutOfSightIsUnreadUntilTheChatShows() async throws {
        let (model, runner, reader, _) = setUp()
        let chat = model.chat
        let kit = try #require(model.store.overseerPlaces.first { $0.rowId == "kit" })
        reader.busy("kit")
        chat.follow([SentPrompt(place: kit, prompt: "pull main", at: Date())], broadcast: "Matchday", host: model.store)
        reader.answers("kit", "Pulled.")
        #expect(await eventually { runner.requests.count == 1 })
        await chat.settle()
        #expect(chat.unread)  // the window was hidden
        model.windowShown(fromHidden: true)
        #expect(!chat.unread)

        // Shown, but on a session's page: unread until the chat is back.
        model.pane = .session("scout")
        let mortgage = try #require(model.store.overseerPlaces.first { $0.rowId == "mortgage" })
        reader.busy("mortgage")
        chat.follow([SentPrompt(place: mortgage, prompt: "pull main", at: Date())], broadcast: "Matchday", host: model.store)
        reader.answers("mortgage", "Pulled.")
        #expect(await eventually { chat.unread })
        model.showChat()
        #expect(!chat.unread)
        #expect(runner.requests.count == 1)  // the private one was never asked about

        // On the chat, a report is read as it lands.
        reader.busy("scout")
        let scout = try #require(model.store.overseerPlaces.first { $0.rowId == "scout" })
        chat.follow([SentPrompt(place: scout, prompt: "pull main", at: Date())], broadcast: "Matchday", host: model.store)
        reader.answers("scout", "Pulled.")
        #expect(await eventually { chat.watching.isEmpty })
        await chat.settle()
        #expect(!chat.unread)
        model.windowHidden()
        #expect(!chat.onScreen)
    }
}
