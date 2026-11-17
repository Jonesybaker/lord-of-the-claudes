/// Splits a shell command into the words the shell would pass to the program, for commands with nothing
/// for the shell to do but quote: no pipes, redirects, chaining, substitution, variables, globs or tilde.
/// Bash and zsh both read such a command the same way. Anything else is refused with a reason.
public enum ShellWords {
    public enum Split: Equatable {
        case words([String])
        case refused(String)
    }

    /// Unquoted characters that are plain in both bash and zsh. A word may not start with `=`, which zsh expands.
    static let plain: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:,=@%+")

    public static func split(_ command: String) -> Split {
        for scalar in command.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D: return .refused("the command has more than one line")
            case 0x09, 0x20...0x7E: continue
            case 0..<0x20, 0x7F: return .refused("the command has a control character")
            default: return .refused("the command has a character outside plain ASCII, such as a look-alike dash")
            }
        }

        var words: [String] = []
        var word = ""
        var inWord = false
        var chars = Array(command)[...]

        func end() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }

        while let c = chars.popFirst() {
            switch c {
            case " ", "\t":
                end()
            case "'":
                inWord = true
                guard let close = chars.firstIndex(of: "'") else { return .refused("the command has an unclosed quote") }
                word += String(chars[..<close])
                chars = chars[(close + 1)...]
            case "\"":
                inWord = true
                var closed = false
                while let d = chars.popFirst() {
                    if d == "\"" { closed = true; break }
                    if d == "$" || d == "`" { return .refused("the command has a $ or backtick inside double quotes") }
                    if d == "!" { return .refused("the command has a ! inside double quotes") }
                    if d == "\\", let next = chars.first, "$`\"\\".contains(next) {
                        word.append(next)
                        chars = chars.dropFirst()
                    } else {
                        word.append(d)
                    }
                }
                guard closed else { return .refused("the command has an unclosed quote") }
            case "\\":
                guard let next = chars.popFirst() else { return .refused("the command ends with a backslash") }
                inWord = true
                word.append(next)
            default:
                if let reason = refusal(for: c, startingWord: !inWord) { return .refused(reason) }
                inWord = true
                word.append(c)
            }
        }
        end()
        return .words(words)
    }

    static func refusal(for c: Character, startingWord: Bool) -> String? {
        if c == "=" && startingWord { return "the command has a word starting with =, which zsh expands" }
        if plain.contains(c) { return nil }
        switch c {
        case "|": return "the command has a pipe"
        case "&": return "the command has a & (background or &&)"
        case ";": return "the command has a ; joining commands"
        case "<", ">": return "the command has a redirect"
        case "`": return "the command has backticks"
        case "$": return "the command has a $ (a variable or a substitution)"
        case "(", ")": return "the command has brackets outside quotes"
        case "*", "?", "[", "]": return "the command has a glob character outside quotes"
        case "{", "}": return "the command has braces outside quotes"
        case "~": return "the command has a ~ outside quotes"
        default: return "the command has a \(c) outside quotes"
        }
    }

    /// The words of any command, split crudely on spaces and shell punctuation: for telling which rule a
    /// command is meant for, never for approving it.
    public static func rough(_ command: String) -> [String] {
        command.split { " \t\r\n;|&()<>`$'\"{}".contains($0) }.map(String.init)
    }
}
