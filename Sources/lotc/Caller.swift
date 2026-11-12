import Darwin
import Foundation
import LotcKit

/// Claude Code's config directory: `CLAUDE_CONFIG_DIR` when set, otherwise `$HOME/.claude`, as Claude Code itself decides.
enum ClaudeHome {
    static var url: URL {
        let environment = ProcessInfo.processInfo.environment
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".claude")
    }
}

/// Which Claude Code session ran this `lotc`. Its Bash tool runs us through a shell or two, so the
/// nearest ancestor process listed in ~/.claude/sessions is the session that asked.
enum Caller {
    static func sessionId(claudeHome: URL) -> String? {
        let registry = sessions(in: claudeHome.appendingPathComponent("sessions"))
        var pid = getppid()
        for _ in 0..<64 where pid > 1 {
            guard let process = ProcessEntry(pid: pid) else { return nil }
            if let session = registry[pid], session.matches(process) { return session.sessionId }
            pid = process.parent
        }
        return nil
    }

    struct Registered {
        let sessionId: String
        let startedAt: Date?

        /// A session file can outlive its process, and after a reboot its pid can belong to something else.
        func matches(_ process: ProcessEntry) -> Bool {
            guard let startedAt else { return true }
            return abs(process.startedAt.timeIntervalSince(startedAt)) < 120
        }
    }

    /// Claude Code's registry of running processes: one `<pid>.json` each.
    static func sessions(in dir: URL) -> [pid_t: Registered] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var registry: [pid_t: Registered] = [:]
        for file in files where file.pathExtension == "json" {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let json = try? JSONValue(parsing: text),
                  case .number(let pidText) = json["pid"], let pid = pid_t(pidText),
                  let sessionId = json["sessionId"]?.string
            else { continue }
            var startedAt: Date?
            if case .number(let ms) = json["startedAt"], let millis = Double(ms) {
                startedAt = Date(timeIntervalSince1970: millis / 1000)
            }
            registry[pid] = Registered(sessionId: sessionId, startedAt: startedAt)
        }
        return registry
    }
}

/// The two facts about a process the caller lookup needs, from the kernel's process table.
struct ProcessEntry {
    let parent: pid_t
    let startedAt: Date

    init?(pid: pid_t) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        parent = info.kp_eproc.e_ppid
        startedAt = Date(timeIntervalSince1970: TimeInterval(info.kp_proc.p_un.__p_starttime.tv_sec))
    }
}
