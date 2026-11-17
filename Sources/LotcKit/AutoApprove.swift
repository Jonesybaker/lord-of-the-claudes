import Foundation

/// The rules that may answer a permission request with yes. A rule never says no: whatever no rule
/// positively recognises goes to the permission window as before.
public enum AutoApproveRule: String, CaseIterable, Codable, Sendable {
    case webSearch = "web-search"
    case publicFetch = "public-fetch"
    case shellGet = "shell-get"
    case readOnlyShell = "read-only-shell"

    public var title: String {
        switch self {
        case .webSearch: "Web search"
        case .publicFetch: "Fetch a public page"
        case .shellGet: "Shell GET with curl or wget"
        case .readOnlyShell: "Read-only shell commands"
        }
    }

    /// Exactly what it approves, in a line.
    public var summary: String {
        switch self {
        case .webSearch:
            "WebSearch, unless the query looks like it holds a secret."
        case .publicFetch:
            "WebFetch of an https page on a public host, with no login, credential-like parameter or secret in the URL or prompt."
        case .shellGet:
            "One curl or wget GET of such a page, with only harmless flags, writing nothing to disk."
        case .readOnlyShell:
            "ls, pwd, and git status, log, diff, show or a branch listing, with flags that cannot write or run anything."
        }
    }

    public var isOnByDefault: Bool { self != .readOnlyShell }
}

/// Kept in auto-approve.json in the app's state directory, never in Claude Code's settings.
/// A missing or unreadable file means everything off; a missing key means its default.
public struct AutoApproveSettings: Codable, Equatable, Sendable {
    /// The master switch. Off on a fresh install.
    public var isOn: Bool
    /// Each rule's own switch, by rule id; a rule not named here has its default.
    public var rules: [String: Bool]
    /// Sessions working in these are never auto-approved, summarised or briefed. `~` allowed.
    public var excludedDirectories: [String]

    public init(isOn: Bool = false, rules: [String: Bool] = [:], excludedDirectories: [String] = []) {
        self.isOn = isOn
        self.rules = rules
        self.excludedDirectories = excludedDirectories
    }

    public func isOn(_ rule: AutoApproveRule) -> Bool { rules[rule.rawValue] ?? rule.isOnByDefault }

    public mutating func set(_ rule: AutoApproveRule, on: Bool) { rules[rule.rawValue] = on }

    enum CodingKeys: String, CodingKey {
        case isOn = "on"
        case rules
        case excludedDirectories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOn = (try? container.decodeIfPresent(Bool.self, forKey: .isOn)) ?? false
        rules = (try? container.decodeIfPresent([String: Bool].self, forKey: .rules)) ?? [:]
        excludedDirectories = (try? container.decodeIfPresent([String].self, forKey: .excludedDirectories)) ?? []
    }

    /// The settings in a file's bytes; everything off when they cannot be read.
    public static func load(_ data: Data?) -> AutoApproveSettings {
        data.flatMap { try? JSONDecoder().decode(AutoApproveSettings.self, from: $0) } ?? AutoApproveSettings()
    }
}

public enum AutoApproveDecision: Equatable, Sendable {
    /// `summary`: what was approved, the query, URL or command.
    case approve(AutoApproveRule, summary: String)
    /// `reason`: why a switched-on rule for this tool said no, for the window to show; nil when none applies.
    case ask(reason: String?)

    /// The quiet line in the permission window.
    public var note: String? {
        guard case .ask(let reason?) = self else { return nil }
        return "Not auto-approved: " + reason
    }
}

/// Decides a PermissionRequest from its tool name, input and directory alone: pure, with no model in it.
public enum AutoApprover {
    /// `directories`: the hook's cwd and, when known, the directory the session started in.
    public static func decide(toolName: String, toolInput: JSONValue, directories: [String],
                              settings: AutoApproveSettings,
                              home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> AutoApproveDecision {
        guard settings.isOn else { return .ask(reason: nil) }
        let verdicts = AutoApproveRule.allCases.filter(settings.isOn).map { ($0, verdict($0, toolName: toolName, input: toolInput)) }
        let claimed = verdicts.filter { $0.1 != .notMine }
        guard !claimed.isEmpty else { return .ask(reason: nil) }
        if directories.contains(where: { ExcludedDirectories.contains($0, in: settings.excludedDirectories, home: home) }) {
            return .ask(reason: "this session works in one of your excluded directories")
        }
        for (rule, verdict) in claimed {
            if case .approve(let summary) = verdict { return .approve(rule, summary: summary) }
        }
        for (_, verdict) in claimed {
            if case .ask(let reason) = verdict { return .ask(reason: reason) }
        }
        return .ask(reason: nil)
    }

    enum Verdict: Equatable {
        /// Not a request this rule is about.
        case notMine
        case approve(summary: String)
        case ask(String)
    }

    static func verdict(_ rule: AutoApproveRule, toolName: String, input: JSONValue) -> Verdict {
        switch rule {
        case .webSearch: return toolName == "WebSearch" ? webSearch(input) : .notMine
        case .publicFetch: return toolName == "WebFetch" ? publicFetch(input) : .notMine
        case .shellGet: return toolName == "Bash" ? shell(input, rule: rule) : .notMine
        case .readOnlyShell: return toolName == "Bash" ? shell(input, rule: rule) : .notMine
        }
    }

    /// The fields each tool's input may have, as Claude Code 2.1.326 sends them. Any other field asks:
    /// a new one could change what the call does.
    static let knownFields: [String: Set<String>] = [
        "WebSearch": ["query", "allowed_domains", "blocked_domains", "mode"],
        "WebFetch": ["url", "prompt", "offset"],
        "Bash": ["command", "description", "timeout", "run_in_background"],
    ]

    static func fieldProblem(_ input: JSONValue, tool: String) -> String? {
        guard let members = input.members else { return "the request's input is not an object" }
        var seen = Set<String>()
        for member in members {
            guard seen.insert(member.key).inserted else { return "the request names \(member.key) twice" }
            guard knownFields[tool]?.contains(member.key) == true else {
                return "the request carries a field the rule does not know: \(ShellGet.clip(member.key))"
            }
        }
        return nil
    }

    /// An optional field is absent or of the right kind.
    static func has(_ value: JSONValue?, _ kind: (JSONValue) -> Bool) -> Bool { value.map(kind) ?? true }

    static func isNumber(_ value: JSONValue) -> Bool { if case .number = value { true } else { false } }

    static func webSearch(_ input: JSONValue) -> Verdict {
        if let problem = fieldProblem(input, tool: "WebSearch") { return .ask(problem) }
        guard let query = input["query"]?.string, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .ask("the search has no query")
        }
        var texts = [query]
        for key in ["allowed_domains", "blocked_domains"] {
            guard let value = input[key] else { continue }
            guard let domains = value.array?.map(\.string), domains.allSatisfy({ $0 != nil }) else {
                return .ask("\(key) is not a list of names")
            }
            texts += domains.compactMap { $0 }
        }
        if !has(input["mode"], { $0.string != nil }) { return .ask("mode is not a word") }
        for text in texts {
            if let secret = SecretDetector.firstMatch(in: text) { return .ask("the search has something that looks like \(secret)") }
        }
        return .approve(summary: query)
    }

    static func publicFetch(_ input: JSONValue) -> Verdict {
        if let problem = fieldProblem(input, tool: "WebFetch") { return .ask(problem) }
        guard let url = input["url"]?.string else { return .ask("the fetch has no URL") }
        if let problem = PublicURL.problem(with: url) { return .ask(problem) }
        if let prompt = input["prompt"] {
            guard let text = prompt.string else { return .ask("the prompt is not text") }
            if let secret = SecretDetector.firstMatch(in: text) { return .ask("the prompt has something that looks like \(secret)") }
        }
        if !has(input["offset"], isNumber) { return .ask("offset is not a number") }
        return .approve(summary: url)
    }

    static func shell(_ input: JSONValue, rule: AutoApproveRule) -> Verdict {
        guard let command = input["command"]?.string else { return .notMine }
        let rough = ShellWords.rough(command)
        let mine = rule == .shellGet
            ? rough.contains { ["curl", "wget"].contains($0) || $0.hasSuffix("/curl") || $0.hasSuffix("/wget") }
            : ReadOnlyCommands.isFor(rough)
        guard mine else { return .notMine }
        if let problem = fieldProblem(input, tool: "Bash") { return .ask(problem) }
        if !has(input["description"], { $0.string != nil }) { return .ask("description is not text") }
        if !has(input["timeout"], isNumber) { return .ask("timeout is not a number") }
        if !has(input["run_in_background"], { if case .bool = $0 { true } else { false } }) {
            return .ask("run_in_background is not true or false")
        }
        let words: [String]
        switch ShellWords.split(command) {
        case .refused(let reason): return .ask(reason)
        case .words(let split): words = split
        }
        switch rule {
        case .shellGet:
            if case .ask(let reason) = ShellGet.check(words) { return .ask(reason) }
        default:
            if case .ask(let reason) = ReadOnlyCommands.check(words) { return .ask(reason) }
        }
        if let secret = SecretDetector.firstMatch(in: command) { return .ask("the command has something that looks like \(secret)") }
        return .approve(summary: command)
    }
}

/// Whether a directory is inside one the user has excluded.
public enum ExcludedDirectories {
    /// Inside means the directory itself or below it: /a/b holds /a/b/c but not /a/bc. Compared without
    /// regard to case, as macOS disks usually are, and through symlinks, so a doubt counts as inside.
    public static func contains(_ path: String, in entries: [String], home: String) -> Bool {
        let roots = entries.compactMap { expand($0, home: home) }
        guard path.hasPrefix("/"), !roots.isEmpty else { return false }
        let forms = spellings(of: path)
        return roots.contains { root in spellings(of: root).contains { root in forms.contains { inside($0, root) } } }
    }

    /// An entry as an absolute path, `~` expanded; nil for an empty or relative one.
    public static func expand(_ entry: String, home: String) -> String? {
        let entry = entry.trimmingCharacters(in: .whitespaces)
        if entry == "~" { return home }
        if entry.hasPrefix("~/") { return home + entry.dropFirst(1) }
        return entry.hasPrefix("/") ? entry : nil
    }

    /// A path as written, tidied, and with its symlinks followed, all lower-cased.
    static func spellings(of path: String) -> Set<String> {
        let tidy = URL(fileURLWithPath: path).standardizedFileURL.path
        var forms: Set<String> = [path, tidy]
        if let real = realpath(tidy, nil) {
            forms.insert(String(cString: real))
            free(real)
        }
        return Set(forms.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()).lowercased() : $0.lowercased() })
    }

    static func inside(_ path: String, _ root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }
}
