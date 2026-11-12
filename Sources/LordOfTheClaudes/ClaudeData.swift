import Darwin
import Foundation

/// A Claude Code process that is running right now inside Ghostty.
struct LiveSession {
    let pid: pid_t
    let sessionId: String
    let cwd: String
    let status: String
    let updatedAt: Date
    /// When `status` last changed, e.g. when Claude finished working.
    let statusUpdatedAt: Date
}

/// What the user has typed into a session, from Claude's prompt history.
struct SessionHistory {
    /// The last few prompts, oldest first.
    var prompts: [(date: Date, text: String)] = []
    /// First Zendesk or Jira link pasted into the session.
    var link: URL?
}

/// Reads Claude Code's own files under ~/.claude. Nothing here writes to them.
/// Not thread-safe: call from one task at a time (the store's poll loop).
final class ClaudeData: @unchecked Sendable {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private var titleCache: [String: (mtime: Date, title: String?)] = [:]
    private var historyCache: (mtime: Date, entries: [String: SessionHistory])?

    // MARK: Live sessions

    /// Claude Code keeps one `<pid>.json` per running process in ~/.claude/sessions.
    /// Files can outlive their process (crash, reboot), so each one is checked against the process table.
    static func liveSessions() -> [LiveSession] {
        let dir = Self.home.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String, UUID(uuidString: sessionId) != nil,
                  let cwd = json["cwd"] as? String,
                  (json["kind"] as? String ?? "interactive") == "interactive"
            else { return nil }
            let startedAt = (json["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            guard ProcessTable.isSameProcess(pid_t(pid), startedAt: startedAt),
                  ProcessTable.isUnderGhostty(pid_t(pid))
            else { return nil }
            let updatedMs = (json["updatedAt"] as? Double) ?? (json["startedAt"] as? Double) ?? 0
            return LiveSession(
                pid: pid_t(pid),
                sessionId: sessionId,
                cwd: cwd,
                status: json["status"] as? String ?? "idle",
                updatedAt: Date(timeIntervalSince1970: updatedMs / 1000),
                statusUpdatedAt: Date(timeIntervalSince1970: ((json["statusUpdatedAt"] as? Double) ?? updatedMs) / 1000)
            )
        }
    }

    // MARK: Titles

    /// The session's name as Claude shows it: a /rename title if set, otherwise the generated one.
    func title(sessionId: String, cwd: String) -> String? {
        guard let url = Self.transcriptURL(sessionId: sessionId, cwd: cwd),
              let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        if let cached = titleCache[sessionId], cached.mtime == mtime { return cached.title }

        // Titles are re-written throughout the transcript, so the tail nearly always has one.
        var title = Self.findTitle(in: Self.readTail(url, bytes: 512 * 1024))
        if title == nil, let whole = try? Data(contentsOf: url) { title = Self.findTitle(in: whole) }
        titleCache[sessionId] = (mtime, title)
        return title
    }

    static func transcriptURL(sessionId: String, cwd: String) -> URL? {
        let projects = Self.home.appendingPathComponent("projects")
        let slug = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let direct = projects.appendingPathComponent(slug).appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // The session may have been started in a different directory from its current cwd.
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent("\(sessionId).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func findTitle(in data: Data) -> String? {
        var custom: String?
        var generated: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Cheap pre-filter: title lines are short, message lines can be megabytes.
            guard line.count < 2000,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }
            if type == "custom-title", let t = json["customTitle"] as? String { custom = t }
            if type == "ai-title", let t = json["aiTitle"] as? String { generated = t }
        }
        return custom ?? generated
    }

    // MARK: Prompt history

    /// Recent prompts per session, from ~/.claude/history.jsonl.
    func history() -> [String: SessionHistory] {
        let url = Self.home.appendingPathComponent("history.jsonl")
        guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return [:] }
        if let cached = historyCache, cached.mtime == mtime { return cached.entries }

        var entries: [String: SessionHistory] = [:]
        for line in Self.readTail(url, bytes: 8 * 1024 * 1024).split(separator: UInt8(ascii: "\n")) {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let sessionId = json["sessionId"] as? String,
                  let ms = json["timestamp"] as? Double
            else { continue }
            let text = json["display"] as? String ?? ""
            var history = entries[sessionId, default: SessionHistory()]
            history.prompts.append((Date(timeIntervalSince1970: ms / 1000), text))
            if history.prompts.count > 5 { history.prompts.removeFirst() }
            if history.link == nil { history.link = Tickets.firstLink(in: text) }
            entries[sessionId] = history
        }
        historyCache = (mtime, entries)
        return entries
    }

    static func readTail(_ url: URL, bytes: UInt64) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return (try? handle.readToEnd()) ?? Data()
    }
}

enum ProcessTable {
    private static func info(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// True if `pid` is alive and started when the session file says it did.
    /// Guards against a stale session file whose pid has been reused since a reboot.
    static func isSameProcess(_ pid: pid_t, startedAt: Date?) -> Bool {
        guard let info = info(pid) else { return false }
        guard let startedAt else { return true }
        let started = Date(timeIntervalSince1970: TimeInterval(info.kp_proc.p_un.__p_starttime.tv_sec))
        return abs(started.timeIntervalSince(startedAt)) < 120
    }

    static func isUnderGhostty(_ pid: pid_t) -> Bool {
        var current = pid
        for _ in 0..<8 {
            guard let info = info(current) else { return false }
            let parent = info.kp_eproc.e_ppid
            if parent <= 1 { return false }
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(parent, &path, UInt32(path.count)) > 0,
               String(cString: path).lowercased().contains("ghostty") {
                return true
            }
            current = parent
        }
        return false
    }
}
