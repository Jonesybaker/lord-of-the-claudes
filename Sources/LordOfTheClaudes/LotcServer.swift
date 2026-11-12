import AppKit
import Combine
import LotcKit

/// Answers `lotc` on a Unix socket: one JSON line in, one JSON line out.
@MainActor
final class LotcServer {
    private static var shared: LotcServer?

    let store: Store
    let permissions = PermissionQueue()
    private let permissionWindow: PermissionWindow
    /// When the app last typed a prompt into each session, so `lotc wait` knows which turn to wait for.
    var lastSentAt: [String: Date] = [:]
    private var countWatch: AnyCancellable?

    static func start(store: Store) {
        guard shared == nil else { return }
        shared = LotcServer(store: store)
    }

    private init(store: Store) {
        self.store = store
        permissionWindow = PermissionWindow(queue: permissions, store: store)
        countWatch = permissions.$requests.sink { [weak store] in store?.permissionRequestCount = $0.count }
        listen()
    }

    private func listen() {
        let listener: LineListener
        do {
            listener = try LineListener(path: LotcSocket.path)
        } catch {
            NSLog("Lord of the Claudes: lotc is unavailable: \(error)")
            return
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in listener.close() }

        // accept() blocks, so it gets a thread of its own.
        Thread { [weak self] in
            while let connection = listener.accept() {
                guard let self else { connection.close(); continue }
                DispatchQueue.global().async { self.serve(connection) }
            }
        }.start()
    }

    private nonisolated func serve(_ connection: LineConnection) {
        guard let request = try? connection.receive(LotcRequest.self, timeout: 5) else {
            connection.close()
            return
        }
        Task {
            let response = await respond(to: request, over: connection)
            try? connection.send(response)
            connection.close()
        }
    }

    private func respond(to request: LotcRequest, over connection: LineConnection) async -> LotcResponse {
        if case .permission(let hookInput) = request.command {
            return .permission(await askPermission(hookInput, over: connection))
        }
        return await run(request.command, caller: request.caller)
    }

    // MARK: Permission requests

    private func askPermission(_ hookInput: String, over connection: LineConnection) async -> PermissionAnswer {
        guard let input = PermissionHookInput(json: hookInput) else { return .askInTerminal }
        let request = PermissionQueue.Request(input: input, origin: origin(of: input))

        // The hook process goes away when the question is answered in the terminal or Claude Code times it out.
        let hangUpWatch = Task.detached { [permissions] in
            while !Task.isCancelled {
                if connection.hasHungUp(within: 0.25) {
                    await permissions.withdraw(request.id)
                    return
                }
            }
        }
        let answer = await permissions.ask(request)
        hangUpWatch.cancel()
        await hangUpWatch.value  // it must stop polling the socket before the socket is closed
        return answer
    }

    /// Subagents share their parent's session id, so they show as the parent's tab.
    private func origin(of input: PermissionHookInput) -> PermissionQueue.Origin {
        let subagent = input.agentType.map { " · subagent \($0)" } ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directory = input.cwd.hasPrefix(home + "/") ? "~" + input.cwd.dropFirst(home.count) : input.cwd
        guard let row = store.rows.first(where: { $0.id == input.sessionId && $0.isLive }) else {
            return .init(sessionId: nil, label: directory + subagent,
                         detail: "Not in a Ghostty tab Lord of the Claudes tracks")
        }
        let group = store.groups.first { $0.rows.contains { $0.id == row.id } }
        let place = [group?.name, row.tab.map { "tab \($0)" }].compactMap { $0 }.joined(separator: ", ")
        let label = place.isEmpty ? row.title : "\(row.title) (\(place))"
        return .init(sessionId: row.id, label: label + subagent, detail: directory)
    }
}
