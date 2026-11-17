import Foundation
import LotcKit

/// The two hooks `lotc hooks install` puts in Claude Code's settings.
enum LotcHook: String, CaseIterable {
    /// Answers permission prompts in the app: `lotc permission` on PermissionRequest.
    case permission
    /// Tells the app Claude has stopped, for the observer's digest: `lotc observe` on Stop.
    case observe

    var event: String {
        switch self {
        case .permission: return "PermissionRequest"
        case .observe: return "Stop"
        }
    }

    /// As `lotc hooks` names it to the user.
    var name: String {
        switch self {
        case .permission: return "permission hook"
        case .observe: return "observer hook"
        }
    }

    /// The group lotc adds under its event. "*" matches every tool (hooks reference, "Matcher patterns");
    /// Stop takes no matcher. The Stop hook runs async, so Claude never waits on it to stop.
    fileprivate func group(_ command: String) -> JSONValue {
        var handler: [JSONMember] = [JSONMember("type", .string("command")), JSONMember("command", .string(command))]
        var group: [JSONMember] = []
        switch self {
        case .permission:
            handler.append(JSONMember("timeout", .number(String(PermissionHook.timeout))))
            group.append(JSONMember("matcher", .string("*")))
        case .observe:
            handler.append(JSONMember("async", .bool(true)))
        }
        group.append(JSONMember("hooks", .array([.object(handler)])))
        return .object(group)
    }
}

/// lotc's hooks in Claude Code's settings, added and removed without disturbing anything else.
enum HookSettings {
    struct Installed: Equatable {
        let hook: LotcHook
        let command: String
        let timeout: Int?
    }

    /// The hook command for the lotc at `path`. Claude Code runs it through `sh -c`, so a path with spaces is quoted.
    static func command(forExecutable path: String, _ hook: LotcHook) -> String {
        let plain = path.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "/._-+@%:,".unicodeScalars.contains($0)
        }
        let program = plain ? path : "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return program + " " + hook.rawValue
    }

    /// The program path in a hook command, if the command is some lotc's `hook`.
    static func lotcPath(inCommand command: String, _ hook: LotcHook) -> String? {
        let suffix = " " + hook.rawValue
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(suffix) else { return nil }
        var program = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        if program.count >= 2, let first = program.first, first == program.last, first == "'" || first == "\"" {
            program = String(program.dropFirst().dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
        }
        return (program as NSString).lastPathComponent == "lotc" ? program : nil
    }

    static func installed(in settings: JSONValue) -> [Installed] {
        LotcHook.allCases.flatMap { hook in
            (settings["hooks"]?[hook.event]?.array ?? []).flatMap { group in
                (group["hooks"]?.array ?? []).compactMap { handler -> Installed? in
                    guard let command = handler["command"]?.string, lotcPath(inCommand: command, hook) != nil else { return nil }
                    var timeout: Int?
                    if case .number(let seconds) = handler["timeout"] { timeout = Int(seconds) }
                    return Installed(hook: hook, command: command, timeout: timeout)
                }
            }
        }
    }

    /// Settings with exactly one of each lotc hook, running the lotc at `path`. A hook already so is left
    /// where it was, even in a group it shares with other hooks.
    static func installing(lotcAt path: String, into settings: JSONValue) -> JSONValue {
        var result = settings
        for hook in LotcHook.allCases {
            let command = command(forExecutable: path, hook)
            if installed(in: result).filter({ $0.hook == hook }).map(\.command) == [command] { continue }

            result = uninstalling(hook, from: result)
            var hooks = result["hooks"] ?? .object([])
            hooks.set(hook.event, .array((hooks[hook.event]?.array ?? []) + [hook.group(command)]))
            result.set("hooks", hooks)
        }
        return result
    }

    /// Settings without any lotc hook. Containers left empty by its removal go too.
    static func uninstalling(from settings: JSONValue) -> JSONValue {
        LotcHook.allCases.reduce(settings) { uninstalling($1, from: $0) }
    }

    private static func uninstalling(_ hook: LotcHook, from settings: JSONValue) -> JSONValue {
        guard var hooks = settings["hooks"], let groups = hooks[hook.event]?.array else { return settings }
        let kept = groups.compactMap { group -> JSONValue? in
            guard let handlers = group["hooks"]?.array else { return group }
            let others = handlers.filter { lotcPath(inCommand: $0["command"]?.string ?? "", hook) == nil }
            if others.count == handlers.count { return group }
            if others.isEmpty { return nil }
            var trimmed = group
            trimmed.set("hooks", .array(others))
            return trimmed
        }
        guard kept != groups else { return settings }
        hooks.set(hook.event, kept.isEmpty ? nil : .array(kept))
        var result = settings
        result.set("hooks", hooks.members?.isEmpty == true ? nil : hooks)
        return result
    }
}

/// `lotc hooks install | uninstall | status`, against Claude Code's user settings.json.
enum HookCommand {
    enum Action: String {
        case install, uninstall, status
    }

    static func run(_ action: Action, settingsURL: URL = ClaudeHome.url.appendingPathComponent("settings.json"),
                    lotcPath: String = ownPath()) -> Int32 {
        let file = SettingsFile(url: settingsURL)
        let settings: JSONValue
        do {
            settings = try file.read()
        } catch {
            return Lotc.fail("\(file.displayPath) could not be read: \(error). Nothing was changed.")
        }
        guard settings.members != nil, settings["hooks"].map({ $0.members != nil }) ?? true else {
            return Lotc.fail("\(file.displayPath) is not shaped as Claude Code expects. Nothing was changed.")
        }

        switch action {
        case .status:
            print(status(of: settings, in: file.displayPath))
            let found = Set(HookSettings.installed(in: settings).map(\.hook))
            return found.count == LotcHook.allCases.count ? 0 : 1

        case .install, .uninstall:
            let before = Set(HookSettings.installed(in: settings).map(\.command))
            let updated = action == .install
                ? HookSettings.installing(lotcAt: lotcPath, into: settings)
                : HookSettings.uninstalling(from: settings)
            guard updated != settings else {
                print(action == .install
                    ? "Both hooks are already installed in \(file.displayPath)."
                    : "No lotc hook is installed in \(file.displayPath).")
                return 0
            }
            do {
                let backup = try file.write(updated)
                if action == .install {
                    let added = HookSettings.installed(in: updated).filter { !before.contains($0.command) }
                    for hook in added { print("Installed the \(hook.hook.name) in \(file.displayPath): \(hook.command)") }
                    print("""
                        While Lord of the Claudes runs, permission prompts open in it, and each time Claude stops \
                        it summarises the session with Haiku.
                        """)
                } else {
                    print("Removed lotc's hooks from \(file.displayPath).")
                }
                if let backup { print("The previous version is at \(backup.path).") }
                return 0
            } catch {
                return Lotc.fail("could not write \(file.displayPath): \(error)")
            }
        }
    }

    /// One line per hook, installed or not.
    static func status(of settings: JSONValue, in displayPath: String) -> String {
        let found = HookSettings.installed(in: settings)
        return LotcHook.allCases.flatMap { hook -> [String] in
            let mine = found.filter { $0.hook == hook }
            guard !mine.isEmpty else { return ["The \(hook.name) is not installed in \(displayPath)."] }
            return mine.flatMap { installed -> [String] in
                let path = HookSettings.lotcPath(inCommand: installed.command, hook) ?? installed.command
                let line = "The \(hook.name) is installed in \(displayPath): \(installed.command)"
                    + (installed.timeout.map { " (timeout \($0)s)" } ?? "")
                return FileManager.default.isExecutableFile(atPath: path)
                    ? [line] : [line, "  but \(path) does not exist; run lotc hooks install again."]
            }
        }.joined(separator: "\n")
    }

    /// This lotc as the user reaches it: a Homebrew symlink stays a symlink, so reinstalling the app does not break the hook.
    static func ownPath() -> String {
        let invoked = CommandLine.arguments[0]
        if invoked.contains("/") { return URL(fileURLWithPath: invoked).standardizedFileURL.path }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(invoked).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return Bundle.main.executablePath ?? invoked
    }
}

/// Claude Code's settings file, read and rewritten as JSON.stringify(_, null, 2) would write it.
struct SettingsFile {
    let url: URL

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// An empty object when the file does not exist yet.
    func read() throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: url.path) else { return .object([]) }
        return try JSONValue(parsing: try String(contentsOf: url, encoding: .utf8))
    }

    /// Writes through a symlink, so a settings file kept in a dotfiles repository stays linked.
    /// Returns the backup of what was there before, if anything was.
    func write(_ settings: JSONValue) throws -> URL? {
        let target = url.resolvingSymlinksInPath()
        let manager = FileManager.default
        var backup: URL?
        var permissions: NSNumber?
        if manager.fileExists(atPath: target.path) {
            let name = "\(target.lastPathComponent).lotc-backup-\(Self.stampFormatter.string(from: Date()))"
            // Never over an earlier backup, even one from the same second.
            let copy = (1...).lazy
                .map { target.deletingLastPathComponent().appendingPathComponent($0 == 1 ? name : "\(name)-\($0)") }
                .first { !manager.fileExists(atPath: $0.path) }!
            try manager.copyItem(at: target, to: copy)
            backup = copy
            permissions = try manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        } else {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data((settings.formatted() + "\n").utf8).write(to: target, options: .atomic)
        if let permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
        return backup
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
