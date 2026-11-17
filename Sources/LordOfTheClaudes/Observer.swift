import Foundation
import LotcKit

/// Writes a digest from a stretch of transcript. A protocol so tests never start the real `claude`.
protocol Summariser: Sendable {
    /// The summariser's reply, as text.
    func summarise(_ excerpt: String) async throws -> String
}

/// The part of a session's transcript the summariser reads.
struct Excerpt: Sendable, Equatable {
    let text: String
    /// Changes whenever the transcript does.
    let fingerprint: String
}

/// Keeps a digest of every session: each time Claude stops, a summariser reads the end of its transcript.
/// One run per session at a time and at most `maxRunning` in all. A stop that comes in while its session
/// waits or runs replaces the one before, and is summarised next. A run that fails or overruns `timeout`
/// changes nothing.
@MainActor
final class Observer {
    nonisolated static let timeout: Duration = .seconds(30)
    nonisolated static let maxRunning = 2
    /// The transcript can lag the stop by a moment, and a burst of stops is worth one run.
    nonisolated static let settle: Duration = .milliseconds(1500)

    private let summariser: Summariser
    private let read: @Sendable (StopEvent) -> Excerpt?
    private let deliver: @MainActor (String, Digest) -> Void
    private let settle: Duration
    private let timeout: Duration
    private let maxRunning: Int

    /// The newest stop of each session not yet read.
    private var latest: [String: StopEvent] = [:]
    /// Sessions with a stop waiting for a free run, oldest first.
    private var queue: [String] = []
    private var running: Set<String> = []
    /// The transcript each session's digest was written from.
    private var summarised: [String: String] = [:]

    var isIdle: Bool { running.isEmpty && queue.isEmpty }

    init(summariser: Summariser, read: @escaping @Sendable (StopEvent) -> Excerpt?,
         settle: Duration = Observer.settle, timeout: Duration = Observer.timeout, maxRunning: Int = Observer.maxRunning,
         deliver: @escaping @MainActor (String, Digest) -> Void) {
        self.summariser = summariser
        self.read = read
        self.settle = settle
        self.timeout = timeout
        self.maxRunning = maxRunning
        self.deliver = deliver
    }

    func stopped(_ event: StopEvent) {
        let id = event.sessionId
        latest[id] = event
        if !running.contains(id) && !queue.contains(id) { queue.append(id) }
        startWhatFits()
    }

    private func startWhatFits() {
        while running.count < maxRunning, !queue.isEmpty {
            let id = queue.removeFirst()
            running.insert(id)
            Task {
                await run(id)
                running.remove(id)
                if latest[id] != nil { queue.append(id) }
                startWhatFits()
            }
        }
    }

    private func run(_ id: String) async {
        try? await Task.sleep(for: settle)
        guard let event = latest.removeValue(forKey: id) else { return }
        let read = self.read
        guard let excerpt = await Task.detached(operation: { read(event) }).value,
              excerpt.fingerprint != summarised[id]
        else { return }
        let summariser = self.summariser
        do {
            let reply = try await withDeadline(timeout) { try await summariser.summarise(excerpt.text) }
            guard let digest = DigestReply.parse(reply, at: Date()) else {
                NSLog("Lord of the Claudes: the summariser's reply had no digest in it")
                return
            }
            summarised[id] = excerpt.fingerprint
            deliver(id, digest)
        } catch {
            NSLog("Lord of the Claudes: no digest this time: \(error)")
        }
    }
}

struct DeadlinePassed: Error, CustomStringConvertible {
    let limit: Duration
    var description: String { "gave up after \(limit)" }
}

/// The operation's result, or `DeadlinePassed` once `limit` has gone by. Stops waiting at the limit even
/// when the operation is slow to notice it has been cancelled.
func withDeadline<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let outcome = Once<Result<T, Error>>()
    return try await withCheckedThrowingContinuation { continuation in
        outcome.onSet { continuation.resume(with: $0) }
        let work = Task {
            do { outcome.set(.success(try await operation())) } catch { outcome.set(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: limit)
            if outcome.set(.failure(DeadlinePassed(limit: limit))) { work.cancel() }
        }
    }
}

/// A value set at most once, from any thread.
final class Once<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var handler: ((Value) -> Void)?

    func onSet(_ handler: @escaping (Value) -> Void) {
        lock.lock()
        if let value {
            lock.unlock()
            handler(value)
        } else {
            self.handler = handler
            lock.unlock()
        }
    }

    /// False when it was set already.
    @discardableResult
    func set(_ newValue: Value) -> Bool {
        lock.lock()
        guard value == nil else { lock.unlock(); return false }
        value = newValue
        let handler = self.handler
        lock.unlock()
        handler?(newValue)
        return true
    }
}

/// What the summariser is asked, and how its reply becomes a `Digest`.
enum DigestReply {
    /// Longer lines are cut: the panel shows one line of each.
    static let lineCap = 160

    static let instructions = """
        You write a three-line status digest of a Claude Code session, for a panel a developer glances at.
        The user message is an excerpt of that session's transcript: its title, its working directory, its first \
        prompt, and its latest exchanges between the developer ("User") and Claude, with the tools Claude ran.
        You are not that session. Do not continue its work, answer its questions or judge whether it could do \
        what it says. Only describe it.
        Reply with exactly these three lines and nothing else:
        GOAL: what the session is for, at most 12 words
        STATE: where the work has got to now, at most 15 words
        BLOCKED: what Claude is waiting for from the developer right now, at most 12 words, or none
        BLOCKED is none unless Claude's last message asks the developer something, waits for a decision or \
        an approval, or cannot go on without them.
        Plain text, no markdown, UK English.
        """

    /// The `GOAL:`, `STATE:` and `BLOCKED:` lines of a reply. Nil without a goal and a state.
    static func parse(_ reply: String, at date: Date) -> Digest? {
        var fields: [String: String] = [:]
        for raw in reply.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
                .drop { "-*•#> ".contains($0) }
                .replacingOccurrences(of: "**", with: "")
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            let name = ["goal": "goal", "state": "state", "blocked": "blocked", "blocked on": "blocked"][key]
            guard let name, fields[name] == nil else { continue }
            fields[name] = clean(String(line[line.index(after: colon)...]))
        }
        guard let goal = fields["goal"], !goal.isEmpty, let state = fields["state"], !state.isEmpty else { return nil }
        let blocked = fields["blocked"].flatMap { isNothing($0) ? nil : $0 }
        return Digest(goal: goal, state: state, blockedOn: blocked, at: date)
    }

    /// `claude -p --output-format json` prints one object: `{"type":"result","is_error":false,"result":"..."}`.
    static func result(fromJSON output: Data) -> String? {
        struct Envelope: Decodable {
            let type: String?
            let is_error: Bool?
            let result: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: output),
              envelope.type == "result", envelope.is_error != true
        else { return nil }
        return envelope.result
    }

    private static func clean(_ value: String) -> String {
        var text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let first = text.first, let last = text.last, text.count >= 2, first == last, "\"'`".contains(first) {
            text = String(text.dropFirst().dropLast())
        }
        return text.count > lineCap ? String(text.prefix(lineCap - 1)) + "…" : text
    }

    private static func isNothing(_ value: String) -> Bool {
        let word = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!-–()"))
        return ["", "none", "nothing", "n/a", "na", "no", "not blocked", "nothing yet"].contains(word)
    }
}
