import Foundation
import LotcKit

/// The auto-approve switches, excluded directories and log, as the app holds them. Read from the state
/// directory once at launch and written back on every change, so the page, the permission hook and
/// `lotc approvals` all see one copy.
@MainActor
final class AutoApprovals: ObservableObject {
    @Published private(set) var settings: AutoApproveSettings
    /// Oldest first.
    @Published private(set) var log: [ApprovalLogEntry]

    /// Where the files live; nil remembers nothing (screenshots and tests).
    struct Files {
        let settings: URL
        let log: URL

        static var standard: Files {
            let dir = Sandbox.isOn
                ? FileManager.default.temporaryDirectory.appendingPathComponent("LordOfTheClaudes-sandbox")
                : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("LordOfTheClaudes")
            return Files(settings: dir.appendingPathComponent("auto-approve.json"),
                         log: dir.appendingPathComponent("auto-approve-log.json"))
        }
    }

    private let files: Files?
    private let home: String

    init(files: Files?, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.files = files
        self.home = home
        settings = AutoApproveSettings.load(files.flatMap { try? Data(contentsOf: $0.settings) })
        log = ApprovalLog.decode(files.flatMap { try? Data(contentsOf: $0.log) })
    }

    /// Made-up switches and log, for the screenshots.
    init(demo settings: AutoApproveSettings, log: [ApprovalLogEntry], home: String = NSHomeDirectory()) {
        files = nil
        self.home = home
        self.settings = settings
        self.log = log
    }

    // MARK: Deciding

    /// `sessionCwd`: the directory the tracked session started in, when it is tracked.
    func decide(_ input: PermissionHookInput, sessionCwd: String?) -> AutoApproveDecision {
        AutoApprover.decide(toolName: input.toolName, toolInput: input.toolInput,
                            directories: [input.cwd] + (sessionCwd.map { [$0] } ?? []), settings: settings, home: home)
    }

    func record(_ rule: AutoApproveRule, summary: String, tool: String, session: String, cwd: String, at date: Date = Date()) {
        log = ApprovalLog.adding(ApprovalLogEntry(at: date, session: session, cwd: cwd, tool: tool, summary: summary,
                                                  rule: rule.rawValue), to: log)
        if let files, let data = ApprovalLog.encode(log) { write(data, to: files.log) }
    }

    func isExcluded(_ directory: String) -> Bool {
        ExcludedDirectories.contains(directory, in: settings.excludedDirectories, home: home)
    }

    func approvedCount(since date: Date) -> Int { ApprovalLog.count(log, since: date) }

    var report: AutoApproveReport { AutoApproveReport(settings: settings, log: log.reversed()) }

    // MARK: Changing

    func setOn(_ on: Bool) { change { $0.isOn = on } }

    func set(_ rule: AutoApproveRule, on: Bool) { change { $0.set(rule, on: on) } }

    /// Adds a directory, written with `~` when it is under the home folder. False for a relative path.
    @discardableResult
    func exclude(_ path: String) -> Bool {
        guard let absolute = ExcludedDirectories.expand(path, home: home) else { return false }
        let tidy = URL(fileURLWithPath: absolute).standardizedFileURL.path
        let entry = tidy == home ? "~" : tidy.hasPrefix(home + "/") ? "~" + tidy.dropFirst(home.count) : tidy
        guard !settings.excludedDirectories.contains(entry) else { return true }
        change { $0.excludedDirectories.append(entry) }
        return true
    }

    func include(_ entry: String) { change { $0.excludedDirectories.removeAll { $0 == entry } } }

    private func change(_ edit: (inout AutoApproveSettings) -> Void) {
        var next = settings
        edit(&next)
        guard next != settings else { return }
        settings = next
        guard let files else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(settings) { write(data, to: files.settings) }
    }

    private func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Lord of the Claudes: could not save \(url.lastPathComponent): \(error)")
        }
    }
}
