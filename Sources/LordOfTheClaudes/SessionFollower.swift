import Foundation

/// A prompt typed into a session, and when, so the wait knows which turn is its.
struct SentPrompt: Equatable {
    let place: SessionPlace
    let prompt: String
    let at: Date
}

/// A session the chat waits on after a prompt went to it.
struct WatchedSession: Identifiable, Equatable {
    let id: UUID
    var place: SessionPlace
    let prompt: String
    /// The prompts sent together, reported together.
    let batch: UUID

    init(place: SessionPlace, prompt: String, batch: UUID = UUID()) {
        id = UUID()
        self.place = place
        self.prompt = prompt
        self.batch = batch
    }
}

/// What became of a session a prompt went to.
struct SessionReply: Equatable {
    enum Outcome: Equatable {
        case finished
        /// Stopped short, waiting on the developer for this.
        case waiting(String)
        case closed
        /// A new session that never showed up.
        case lost
    }

    var place: SessionPlace
    let prompt: String
    let outcome: Outcome
    /// Its final words, capped later. Always empty for a private session, which is never read.
    let answer: String
}

/// Waits on every session a prompt went to and hands on what each said: public ones together, or as they come
/// when one lags; private ones only as having stopped, never read.
@MainActor
final class SessionFollower {
    struct Timing {
        var poll: Duration = .seconds(1)
        /// How long a batch waits for its slowest session after the first has stopped.
        var straggler: Duration = .seconds(120)
        /// How long a new tab may take to start Claude Code.
        var newSession: TimeInterval = 60
    }

    private struct Batch {
        var waiting: Set<UUID>
        var stopped: [SessionReply] = []
        var asTheyCome = false
        var straggler: Task<Void, Never>?
        /// The group a broadcast went to.
        let broadcast: String?
    }

    let reader: SessionReading
    let timing: Timing
    private(set) var watching: [WatchedSession] = [] { didSet { onWatching(watching) } }
    var onWatching: @MainActor ([WatchedSession]) -> Void = { _ in }
    /// Public sessions' replies; `broadcast` names the group when they came from its megaphone.
    var onReplies: @MainActor (_ replies: [SessionReply], _ broadcast: String?) -> Void = { _, _ in }
    /// A private session stopped or closed. Only the app may say so.
    var onPrivate: @MainActor (SessionReply) -> Void = { _ in }
    /// A directory excluded since the prompt went: its session is not read either.
    var isExcluded: @MainActor (SessionPlace) -> Bool = { _ in false }

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var batches: [UUID: Batch] = [:]

    init(reader: SessionReading, timing: Timing = Timing()) {
        self.reader = reader
        self.timing = timing
    }

    func follow(_ sends: [SentPrompt], broadcast: String? = nil) {
        guard !sends.isEmpty else { return }
        let batch = UUID()
        let items = sends.map { WatchedSession(place: $0.place, prompt: $0.prompt, batch: batch) }
        let shared = items.filter { !$0.place.isPrivate }.map(\.id)
        if !shared.isEmpty { batches[batch] = Batch(waiting: Set(shared), broadcast: broadcast) }
        watching += items
        for (item, send) in zip(items, sends) {
            tasks[item.id] = Task { [weak self] in await self?.run(item, since: send.at) }
        }
    }

    /// A new tab: its session is found by directory once Claude Code registers it.
    func followNew(cwd: String, group: String?, windowId: String?, prompt: String, at: Date, isPrivate: Bool) {
        let place = SessionPlace(rowId: "", group: group ?? "Other", windowId: windowId, tab: nil, title: "The new session",
                                 cwd: cwd, isPrivate: isPrivate)
        let item = WatchedSession(place: place, prompt: prompt)
        if !isPrivate { batches[item.batch] = Batch(waiting: [item.id], broadcast: nil) }
        watching.append(item)
        tasks[item.id] = Task { [weak self] in await self?.runNew(item, at: at) }
    }

    func stopWatching(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        guard let item = watching.first(where: { $0.id == id }) else { return }
        watching.removeAll { $0.id == id }
        guard var batch = batches[item.batch], batch.waiting.remove(id) != nil else { return }
        batches[item.batch] = batch
        if batch.waiting.isEmpty { finish(item.batch) }
    }

    func stopAll() {
        tasks.values.forEach { $0.cancel() }
        batches.values.forEach { $0.straggler?.cancel() }
        tasks = [:]
        batches = [:]
        watching = []
    }

    // MARK: Waiting

    /// Waits until it stops; one that stopped for the developer is watched on until it finishes.
    private func run(_ item: WatchedSession, since sentAt: Date) async {
        var since = sentAt
        while !Task.isCancelled {
            let id = item.place.rowId
            let outcome = await TurnWatch.wait(sentAt: since, every: timing.poll) { [reader] in await reader.status(of: id) }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .cancelled, .timedOut:
                return
            case .closed:
                stopped(item.id, outcome: .closed, answer: "")
                return
            case .finished(let status):
                let current = watching.first { $0.id == item.id } ?? item
                let answer = current.place.isPrivate || isExcluded(current.place) ? "" : await lastAnswer(of: current.place)
                guard !Task.isCancelled else { return }
                guard let reason = status.stoppedFor else {
                    stopped(item.id, outcome: .finished, answer: answer)
                    return
                }
                stopped(item.id, outcome: .waiting(reason), answer: answer)
                since = status.changedAt
            }
        }
    }

    /// Finds the new tab's session, waits for it to start on the prompt, then as for any other.
    private func runNew(_ item: WatchedSession, at: Date) async {
        let deadline = Date().addingTimeInterval(timing.newSession)
        var found: (id: String, startedAt: Date)?
        while found == nil, !Task.isCancelled {
            found = await reader.newSession(in: item.place.cwd, since: at.addingTimeInterval(-1))
            if found == nil {
                guard Date() < deadline else { return stopped(item.id, outcome: .lost, answer: "") }
                try? await Task.sleep(for: timing.poll)
            }
        }
        guard let found, !Task.isCancelled else { return }
        var place = item.place
        place = SessionPlace(rowId: found.id, group: place.group, windowId: place.windowId, tab: nil, title: place.title,
                             cwd: place.cwd, isPrivate: place.isPrivate)
        if let index = watching.firstIndex(where: { $0.id == item.id }) { watching[index].place = place }
        // Its first moments are Claude Code starting up, not the prompt done: wait to see it busy, or a change after start-up.
        var since = found.startedAt.addingTimeInterval(Waiting.startUp)
        while !Task.isCancelled {
            guard let status = await reader.status(of: found.id) else { return stopped(item.id, outcome: .closed, answer: "") }
            if status.status == "busy" { since = Date(); break }
            if status.changedAt > since { break }
            try? await Task.sleep(for: timing.poll)
        }
        var started = item
        started.place = place
        await run(started, since: since)
    }

    /// The transcript can lag the status by a moment.
    private func lastAnswer(of place: SessionPlace) async -> String {
        for attempt in 0..<3 {
            if let answer = await reader.exchanges(of: place.rowId, cwd: place.cwd, last: 1).last?.answer, !answer.isEmpty {
                return answer
            }
            if attempt < 2 { try? await Task.sleep(for: timing.poll) }
        }
        return ""
    }

    // MARK: Reporting

    private func stopped(_ id: UUID, outcome: SessionReply.Outcome, answer: String) {
        guard let item = watching.first(where: { $0.id == id }) else { return }
        if case .waiting = outcome {} else {
            watching.removeAll { $0.id == id }
            tasks[id] = nil
        }
        let reply = SessionReply(place: item.place, prompt: item.prompt, outcome: outcome, answer: item.place.isPrivate ? "" : answer)
        if item.place.isPrivate { return onPrivate(reply) }
        guard var batch = batches[item.batch], batch.waiting.remove(id) != nil else { return onReplies([reply], nil) }
        batch.stopped.append(reply)
        batches[item.batch] = batch
        if batch.waiting.isEmpty || batch.asTheyCome {
            finish(item.batch)
        } else if batch.straggler == nil {
            let key = item.batch
            batches[key]?.straggler = Task { [weak self, timing] in
                try? await Task.sleep(for: timing.straggler)
                guard !Task.isCancelled else { return }
                self?.stragglerDue(key)
            }
        }
    }

    /// The rest are slow: report those done, then each of the rest as it comes.
    private func stragglerDue(_ key: UUID) {
        guard var batch = batches[key], !batch.waiting.isEmpty else { return }
        batch.asTheyCome = true
        let done = batch.stopped
        batch.stopped = []
        batches[key] = batch
        if !done.isEmpty { onReplies(done, batch.broadcast) }
    }

    /// Hands on what the batch has; it is done once nothing in it is waited on.
    private func finish(_ key: UUID) {
        guard var batch = batches[key] else { return }
        let done = batch.stopped
        batch.stopped = []
        if batch.waiting.isEmpty {
            batch.straggler?.cancel()
            batches[key] = nil
        } else {
            batches[key] = batch
        }
        if !done.isEmpty { onReplies(done, batch.broadcast) }
    }
}
