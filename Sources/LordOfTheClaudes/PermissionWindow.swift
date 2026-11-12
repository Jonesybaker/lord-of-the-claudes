import AppKit
import Carbon.HIToolbox
import Combine
import LotcKit
import SwiftUI

/// Keys the permission window answers to. Plain Return never approves: the window takes focus
/// by itself, and the user may be halfway through a sentence in another app.
enum PermissionKey: Equatable {
    case approve  // Cmd+Return
    case deny  // Cmd+D
    case answerInTerminal  // Esc

    init?(_ event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) {
            self = .approve
        } else if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "d" {
            self = .deny
        } else if modifiers.isEmpty, Int(event.keyCode) == kVK_Escape {
            self = .answerInTerminal
        } else {
            return nil
        }
    }
}

/// The floating window that puts each waiting permission question to the user in turn.
@MainActor
final class PermissionWindow: ObservableObject {
    /// "Tell Claude what to do instead", for the question on screen.
    @Published var instead = ""

    static let plainDenial = "The user denied this in Lord of the Claudes."

    private let queue: PermissionQueue
    private let store: Store
    private var panel: PermissionPanel?
    /// The app the user was in when the window took focus, to hand focus back to.
    private var previousApp: NSRunningApplication?
    private var shownId: UUID?
    private var watch: AnyCancellable?
    private var keyMonitor: Any?

    init(queue: PermissionQueue, store: Store) {
        self.queue = queue
        self.store = store
        // Delivered a beat later, once `requests` holds the new value.
        watch = queue.$requests.receive(on: RunLoop.main).sink { [weak self] requests in
            self?.update(front: requests.first?.id)
        }
    }

    // MARK: Answers

    func press(_ key: PermissionKey) {
        switch key {
        case .approve: approve()
        case .deny: deny()
        case .answerInTerminal: answerInTerminal()
        }
    }

    func approve() {
        answerFront(.allow)
    }

    /// With instructions typed, Claude reads them and carries on. Without, it stops, as at the terminal's "No".
    func deny() {
        let text = instead.trimmingCharacters(in: .whitespacesAndNewlines)
        answerFront(text.isEmpty
            ? .deny(message: Self.plainDenial, interrupt: true)
            : .deny(message: text, interrupt: false))
    }

    /// Return in the text field. Only with something typed, so a stray Return does nothing.
    func submitInstead() {
        guard !instead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        deny()
    }

    func answerInTerminal() {
        guard let request = queue.front, queue.isFrontArmed else { return }
        let row = request.origin.sessionId.flatMap { id in store.rows.first { $0.id == id && $0.isLive } }
        if row != nil { previousApp = nil }  // Ghostty takes focus instead
        queue.answer(request.id, with: .askInTerminal)
        if let row { store.focus(row) }
    }

    private func answerFront(_ answer: PermissionAnswer) {
        guard let request = queue.front, queue.isFrontArmed else { return }
        queue.answer(request.id, with: answer)
    }

    // MARK: Window

    private func update(front: UUID?) {
        if front != shownId {
            instead = ""
            shownId = front
        }
        if front == nil { hide() } else { show() }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        guard !panel.isVisible else { return }
        let frontApp = NSWorkspace.shared.frontmostApplication
        previousApp = frontApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontApp
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        // Nothing in it has the keyboard until the user picks something, so typing meant for another app goes nowhere.
        panel.makeFirstResponder(nil)
        DispatchQueue.main.async { panel.makeFirstResponder(nil) }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        if NSApp.isActive { previousApp?.activate() }
        previousApp = nil
    }

    private func makePanel() -> PermissionPanel {
        let panel = PermissionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Lord of the Claudes"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: PermissionView(queue: queue, prompt: self))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
        self.panel = panel
        return panel
    }

    /// Sees each key press before the text field and SwiftUI do, so each key has one meaning.
    /// Returns nil for a key it has used.
    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window === panel, let key = PermissionKey(event) else { return event }
        if !event.isARepeat { press(key) }
        return nil
    }
}

final class PermissionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Esc is the "Answer in the terminal" key; the panel must not close itself and strand the question.
    override func cancelOperation(_ sender: Any?) {}
}

// MARK: Views

struct PermissionView: View {
    @ObservedObject var queue: PermissionQueue
    @ObservedObject var prompt: PermissionWindow
    @State private var armed = false

    var body: some View {
        if let request = queue.front {
            question(request)
                .task(id: request.id) {
                    armed = false
                    try? await Task.sleep(for: .seconds(PermissionQueue.armingDelay))
                    armed = true
                }
        } else {
            Color.clear.frame(width: 640, height: 1)
        }
    }

    private func question(_ request: PermissionQueue.Request) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(ToolPreview.headline(toolName: request.input.toolName)).font(.title3.weight(.semibold))
                Spacer()
                if queue.requests.count > 1 {
                    Text("1 of \(queue.requests.count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(request.origin.label).font(.headline)
                Text(request.origin.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            PreviewBody(preview: ToolPreview(toolName: request.input.toolName, input: request.input.toolInput))
            TextField("Tell Claude what to do instead (Return sends it)", text: $prompt.instead)
                .textFieldStyle(.roundedBorder)
                .onSubmit { prompt.submitInstead() }
            HStack(spacing: 10) {
                Button { prompt.answerInTerminal() } label: { KeyLabel(title: "Answer in the terminal", key: "esc") }
                    .accessibilityLabel("Answer in the terminal")
                Spacer()
                Button { prompt.deny() } label: { KeyLabel(title: "Deny", key: "⌘D") }
                    .accessibilityLabel("Deny")
                Button { prompt.approve() } label: { KeyLabel(title: "Approve", key: "⌘↩") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Approve")
            }
            .disabled(!armed)
        }
        .padding(16)
        .frame(width: 640)
    }
}

private struct KeyLabel: View {
    let title: String
    let key: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(key).foregroundStyle(.secondary)
        }
    }
}

private struct PreviewBody: View {
    let preview: ToolPreview

    var body: some View {
        switch preview {
        case .command(let command, let description):
            VStack(alignment: .leading, spacing: 6) {
                if let description, !description.isEmpty { Text(description).font(.callout) }
                CodeBox(text: command, maxHeight: 260)
            }
        case .edit(let file, let old, let new, let everyOccurrence):
            VStack(alignment: .leading, spacing: 6) {
                FileName(path: file)
                Caption(text: everyOccurrence ? "Replace every occurrence of" : "Replace")
                CodeBox(text: old, maxHeight: 160, tint: .red)
                Caption(text: "With")
                CodeBox(text: new, maxHeight: 160, tint: .green)
            }
        case .write(let file, let content):
            VStack(alignment: .leading, spacing: 6) {
                FileName(path: file)
                CodeBox(text: content, maxHeight: 300)
            }
        case .json(let json):
            CodeBox(text: json, maxHeight: 300)
        }
    }
}

private struct FileName: View {
    let path: String
    var body: some View { Text(path).font(.callout.monospaced()).textSelection(.enabled) }
}

private struct Caption: View {
    let text: String
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}

private struct CodeHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Monospaced text that scrolls once it is taller than `maxHeight`.
private struct CodeBox: View {
    let text: String
    let maxHeight: CGFloat
    var tint: Color? = nil
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            Text(Self.clipped(text))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(GeometryReader { Color.clear.preference(key: CodeHeight.self, value: $0.size.height) })
        }
        // A bare ScrollView has no height of its own, so size it to its text up to the cap.
        .frame(height: min(maxHeight, max(height, 24)))
        .onPreferenceChange(CodeHeight.self) { height = $0 }
        .background(RoundedRectangle(cornerRadius: 6).fill((tint ?? .primary).opacity(tint == nil ? 0.05 : 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    /// Very long text makes SwiftUI crawl, and nobody reads that far in a permission prompt.
    static func clipped(_ text: String, limit: Int = 20_000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… \(text.count - limit) more characters not shown"
    }
}
