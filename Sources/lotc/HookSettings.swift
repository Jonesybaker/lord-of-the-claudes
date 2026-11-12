import Foundation
import LotcKit

/// lotc's PermissionRequest hook in Claude Code's settings, added and removed without disturbing anything else.
enum HookSettings {
    struct Installed: Equatable {
        let command: String
        let timeout: Int?
    }

    /// The hook command for the lotc at `path`. Claude Code runs it through `sh -c`, so a path with spaces is quoted.
    static func command(forExecutable path: String) -> String {
        let plain = path.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "/._-+@%:,".unicodeScalars.contains($0)
        }
        let program = plain ? path : "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return program + " permission"
    }

    /// The program path in a hook command, if the command is some lotc's permission hook.
    static func lotcPath(inCommand command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(" permission") else { return nil }
        var program = String(trimmed.dropLast(" permission".count)).trimmingCharacters(in: .whitespaces)
        if program.count >= 2, let first = program.first, first == program.last, first == "'" || first == "\"" {
            program = String(program.dropFirst().dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
        }
        return (program as NSString).lastPathComponent == "lotc" ? program : nil
    }

    static func installed(in settings: JSONValue) -> [Installed] {
        let groups = settings["hooks"]?["PermissionRequest"]?.array ?? []
        return groups.flatMap { group in
            (group["hooks"]?.array ?? []).compactMap { handler in
                guard let command = handler["command"]?.string, lotcPath(inCommand: command) != nil else { return nil }
                var timeout: Int?
                if case .number(let seconds) = handler["timeout"] { timeout = Int(seconds) }
                return Installed(command: command, timeout: timeout)
            }
        }
    }

    /// Settings with exactly one lotc hook, running `command`; unchanged when that is already so.
    static func installing(_ command: String, into settings: JSONValue) -> JSONValue {
        let wanted = hookGroup(command)
        let groups = settings["hooks"]?["PermissionRequest"]?.array ?? []
        if groups.contains(wanted), installed(in: settings).count == 1 { return settings }

        var result = uninstalling(from: settings)
        var hooks = result["hooks"] ?? .object([])
        hooks.set("PermissionRequest", .array((hooks["PermissionRequest"]?.array ?? []) + [wanted]))
        result.set("hooks", hooks)
        return result
    }

    /// Settings without any lotc hook. Containers left empty by its removal go too.
    static func uninstalling(from settings: JSONValue) -> JSONValue {
        guard var hooks = settings["hooks"], let groups = hooks["PermissionRequest"]?.array else { return settings }
        let kept = groups.compactMap { group -> JSONValue? in
            guard let handlers = group["hooks"]?.array else { return group }
            let others = handlers.filter { lotcPath(inCommand: $0["command"]?.string ?? "") == nil }
            if others.count == handlers.count { return group }
            if others.isEmpty { return nil }
            var trimmed = group
            trimmed.set("hooks", .array(others))
            return trimmed
        }
        guard kept != groups else { return settings }
        hooks.set("PermissionRequest", kept.isEmpty ? nil : .array(kept))
        var result = settings
        result.set("hooks", hooks.members?.isEmpty == true ? nil : hooks)
        return result
    }

    /// "*" matches every tool (hooks reference, "Matcher patterns").
    private static func hookGroup(_ command: String) -> JSONValue {
        .object([
            JSONMember("matcher", .string("*")),
            JSONMember("hooks", .array([
                .object([
                    JSONMember("type", .string("command")),
                    JSONMember("command", .string(command)),
                    JSONMember("timeout", .number(String(PermissionHook.timeout))),
                ]),
            ])),
        ])
    }
}

/// `lotc hooks install | uninstall | status`, against Claude Code's user settings.json.
enum HookCommand {
    enum Action: String {
        case install, uninstall, status
    }

    static func run(_ action: Action, settingsURL: URL = ClaudeHome.url.appendingPathComponent("settings.json")) -> Int32 {
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
            let found = HookSettings.installed(in: settings)
            guard !found.isEmpty else {
                print("The permission hook is not installed in \(file.displayPath).")
                return 1
            }
            for hook in found {
                let path = HookSettings.lotcPath(inCommand: hook.command) ?? hook.command
                let exists = FileManager.default.isExecutableFile(atPath: path)
                print("Installed in \(file.displayPath): \(hook.command)" + (hook.timeout.map { " (timeout \($0)s)" } ?? ""))
                if !exists { print("  but \(path) does not exist; run lotc hooks install again.") }
            }
            return 0

        case .install, .uninstall:
            let updated = action == .install
                ? HookSettings.installing(HookSettings.command(forExecutable: ownPath()), into: settings)
                : HookSettings.uninstalling(from: settings)
            guard updated != settings else {
                print(action == .install
                    ? "The permission hook is already installed in \(file.displayPath)."
                    : "The permission hook is not installed in \(file.displayPath).")
                return 0
            }
            do {
                let backup = try file.write(updated)
                print(action == .install
                    ? "Installed the permission hook in \(file.displayPath). Permission prompts now open in Lord of the Claudes while it runs."
                    : "Removed the permission hook from \(file.displayPath).")
                if let backup { print("The previous version is at \(backup.path).") }
                return 0
            } catch {
                return Lotc.fail("could not write \(file.displayPath): \(error)")
            }
        }
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
