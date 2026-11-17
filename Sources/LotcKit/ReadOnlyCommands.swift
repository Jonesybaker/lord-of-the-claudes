/// A short fixed list of commands that only look: `ls`, `pwd`, and git's status, log, diff, show and
/// branch listings, each with only flags that cannot write or run anything. Left out when unsure.
enum ReadOnlyCommands {
    enum Verdict: Equatable {
        case approve
        case ask(String)
    }

    static let gitCommands = ["status", "log", "diff", "show", "branch"]

    /// Whether a command is meant for this rule, from its rough words: decides only whether the
    /// permission window says why it was not approved.
    static func isFor(_ rough: [String]) -> Bool {
        guard let first = rough.first else { return false }
        if first == "ls" || first == "pwd" { return true }
        let rest = rough.dropFirst().filter { $0 != "--no-pager" }
        return first == "git" && rest.first.map(gitCommands.contains) == true
    }

    static func check(_ words: [String]) -> Verdict {
        guard let program = words.first else { return .ask("the command is empty") }
        let args = Array(words.dropFirst())
        switch program {
        case "ls": return ls(args)
        case "pwd": return args.allSatisfy(["-L", "-P"].contains) ? .approve : .ask("pwd takes no arguments here")
        case "git": return git(args)
        default: return .ask("the command is not one of ls, pwd or a git listing")
        }
    }

    static let lsLetters: Set<Character> = Set("aAlh1RtrSdFGp")

    static func ls(_ args: [String]) -> Verdict {
        for arg in args where arg.hasPrefix("-") {
            guard arg.count > 1, !arg.hasPrefix("--"), arg.dropFirst().allSatisfy(lsLetters.contains) else {
                return .ask("the ls flag \(ShellGet.clip(arg)) is not one the rule allows")
            }
        }
        return .approve
    }

    /// Flags each git listing may have. Paths and revisions are fine; anything else starting with - asks.
    static let gitFlags: [String: Set<String>] = [
        "status": ["-s", "--short", "-b", "--branch", "-sb", "-bs", "--porcelain", "--porcelain=v1", "--porcelain=v2",
                   "-uno", "--untracked-files=no", "--no-color"],
        "log": ["--oneline", "--graph", "--decorate", "--no-decorate", "--all", "--reverse", "--no-merges", "--first-parent",
                "--abbrev-commit", "--no-color", "--pretty=oneline", "--pretty=short", "--pretty=medium", "--pretty=full",
                "--pretty=fuller", "--pretty=reference"],
        "diff": ["--cached", "--staged", "--name-only", "--name-status", "--no-ext-diff", "--no-textconv", "--no-color"],
        "show": ["--name-only", "--name-status", "--oneline", "--no-patch", "-s", "--no-ext-diff", "--no-textconv", "--no-color"],
        "branch": ["-a", "-r", "-v", "-vv", "-l", "--list", "--all", "--remotes", "--show-current", "--no-color"],
    ]

    static func git(_ args: [String]) -> Verdict {
        var args = args[...]
        if args.first == "--no-pager" { args = args.dropFirst() }
        guard let command = args.popFirst() else { return .ask("git needs a command") }
        guard let flags = gitFlags[command] else {
            return .ask(command.hasPrefix("-") ? "git's own flag \(ShellGet.clip(command)) is not one the rule allows"
                                                : "git \(ShellGet.clip(command)) is not a listing the rule knows")
        }
        var afterSeparator = false
        while let arg = args.popFirst() {
            if afterSeparator { continue }
            if arg == "--" {
                afterSeparator = true
            } else if command == "log", arg == "-n", let count = args.first, count.allSatisfy(\.isASCIIDigit), !count.isEmpty {
                args = args.dropFirst()
            } else if command == "log", isCount(arg) {
                continue
            } else if arg.hasPrefix("-") {
                guard flags.contains(arg) else { return .ask("the flag \(ShellGet.clip(arg)) is not one the rule allows for git \(command)") }
            } else if command == "branch" {
                return .ask("git branch with a name makes a branch")
            }
        }
        if command == "branch", afterSeparator { return .ask("git branch with a name makes a branch") }
        return .approve
    }

    /// `-5`, `-n5`, `--max-count=5`.
    static func isCount(_ arg: String) -> Bool {
        for prefix in ["--max-count=", "-n", "-"] where arg.hasPrefix(prefix) {
            let digits = arg.dropFirst(prefix.count)
            if !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) { return true }
        }
        return false
    }
}
