import Foundation

/// One curl or wget GET of a public page, with only flags known to be harmless. Every other flag asks,
/// which rules out by construction other methods, bodies, uploads, credentials, cookies, config files,
/// proxies, sockets, name overrides and writing files.
enum ShellGet {
    enum Verdict: Equatable {
        case approve
        case ask(String)
    }

    static func check(_ words: [String]) -> Verdict {
        switch words.first {
        case "curl": return check(Array(words.dropFirst()), as: .curl)
        case "wget": return check(Array(words.dropFirst()), as: .wget)
        default: return .ask("the command is not curl or wget on its own")
        }
    }

    /// What one flag may be given, checked before it is accepted.
    enum Value {
        case none
        case number
        case anyText
        case header
        case output
        case method
        case writeOut
    }

    struct Tool {
        let name: String
        let short: [Character: Value]
        let long: [String: Value]
        /// Whole words taken as they are, such as wget's `-nv`.
        var exact: Set<String> = []
        /// Accepts `--name=value` as well as `--name value`. curl does not.
        var longEquals = false

        static let curl = Tool(
            name: "curl",
            short: ["s": .none, "S": .none, "f": .none, "I": .none,
                    "m": .number, "A": .anyText, "H": .header, "o": .output, "w": .writeOut, "X": .method],
            long: ["--silent": .none, "--show-error": .none, "--fail": .none, "--head": .none,
                   "--compressed": .none, "--max-time": .number, "--connect-timeout": .number, "--user-agent": .anyText,
                   "--header": .header, "--output": .output, "--write-out": .writeOut, "--request": .method])

        static let wget = Tool(
            name: "wget",
            short: ["q": .none, "S": .none, "O": .output, "T": .number, "U": .anyText],
            long: ["--quiet": .none, "--server-response": .none, "--spider": .none, "--no-verbose": .none,
                   "--output-document": .output, "--timeout": .number, "--connect-timeout": .number,
                   "--user-agent": .anyText, "--header": .header],
            exact: ["-nv", "--max-redirect=0"], longEquals: true)
    }

    static func check(_ args: [String], as tool: Tool) -> Verdict {
        var urls: [String] = []
        var outputs: [String] = []
        var spider = false
        var index = 0

        func take(_ value: Value, flag: String, glued: String?) -> String? {
            if let glued, !glued.isEmpty { return glued }
            guard index + 1 < args.count else { return nil }
            index += 1
            return args[index]
        }

        func accept(_ value: Value, flag: String, _ given: String?) -> String? {
            guard value != .none else { return nil }
            guard let given else { return "\(flag) has no value" }
            if let problem = problem(with: given, as: value, flag: flag, tool: tool) { return problem }
            if value == .output { outputs.append(given) }
            return nil
        }

        while index < args.count {
            let arg = args[index]
            if tool.exact.contains(arg) {
                index += 1
                continue
            }
            if arg.hasPrefix("--") {
                var name = arg
                var glued: String?
                if tool.longEquals, let equals = arg.firstIndex(of: "=") {
                    name = String(arg[..<equals])
                    glued = String(arg[arg.index(after: equals)...])
                }
                guard let value = tool.long[name] else { return .ask("the flag \(clip(name)) is not one the rule allows") }
                if name == "--spider" { spider = true }
                if value == .none, glued != nil { return .ask("the flag \(clip(name)) takes no value") }
                let given = value == .none ? nil : take(value, flag: name, glued: glued)
                if let problem = accept(value, flag: name, given) { return .ask(problem) }
            } else if arg.hasPrefix("-") && arg.count > 1 {
                // A cluster such as -sSL; a flag that takes a value takes the rest of the word, or the next word.
                var letters = arg.dropFirst()[...]
                while let letter = letters.popFirst() {
                    guard let value = tool.short[letter] else {
                        return .ask("the flag -\(letter) is not one the rule allows")
                    }
                    guard value != .none else { continue }
                    let given = take(value, flag: "-\(letter)", glued: String(letters))
                    if let problem = accept(value, flag: "-\(letter)", given) { return .ask(problem) }
                    break
                }
            } else if arg.hasPrefix("-") {
                return .ask("the command has a bare -")
            } else {
                urls.append(arg)
            }
            index += 1
        }

        guard urls.count == 1 else {
            return .ask(urls.isEmpty ? "the command has no URL" : "the command fetches more than one URL")
        }
        if let problem = PublicURL.problem(with: urls[0]) { return .ask(problem) }
        // A redirect could point at localhost after the URL passed its checks. curl follows none unless told to.
        if tool.name == "wget", !args.contains("--max-redirect=0") {
            return .ask("wget follows redirects unless given --max-redirect=0")
        }
        if tool.name == "wget", outputs.isEmpty, !spider {
            return .ask("wget saves the page to a file unless given -O - or -O /dev/null")
        }
        return .approve
    }

    static func problem(with given: String, as value: Value, flag: String, tool: Tool) -> String? {
        switch value {
        case .none, .anyText:
            return nil
        case .number:
            let parts = given.split(separator: ".", omittingEmptySubsequences: false)
            let plain = (1...2).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }
            return plain ? nil : "\(flag) needs a plain number"
        case .header:
            return headerProblem(given)
        case .output:
            let allowed = tool.name == "wget" ? ["-", "/dev/null"] : ["/dev/null"]
            return allowed.contains(given) ? nil : "the output goes to \(clip(given)) (\(flag)), not \(allowed.joined(separator: " or "))"
        case .method:
            return given == "GET" ? nil : "the method is \(clip(given)), not GET"
        case .writeOut:
            return WriteOut.isPlain(given) ? nil : "-w uses a format the rule does not know"
        }
    }

    static let allowedHeaders: Set<String> = ["accept", "accept-language"]

    static func headerProblem(_ header: String) -> String? {
        guard let colon = header.firstIndex(of: ":") else { return "the header \(clip(header)) is not a Name: value header" }
        let name = header[..<colon].trimmingCharacters(in: .whitespaces)
        guard allowedHeaders.contains(name.lowercased()) else {
            return "the header \(clip(name)) is not Accept or Accept-Language"
        }
        return nil
    }

    static func clip(_ text: String) -> String {
        text.count > 40 ? String(text.prefix(40)) + "…" : text
    }
}

/// curl's `-w` formats that only print numbers and names about the transfer. `%output{}`, `%header{}`,
/// `@file` and the rest ask: one of them writes a file and another reads one.
enum WriteOut {
    static let variables: Set<String> = [
        "http_code", "response_code", "http_version", "scheme", "url", "url_effective", "redirect_url", "num_redirects",
        "content_type", "remote_ip", "remote_port", "size_download", "size_header", "size_request", "speed_download",
        "time_total", "time_connect", "time_namelookup", "time_appconnect", "time_pretransfer", "time_redirect",
        "time_starttransfer", "exitcode", "errormsg",
    ]
    static let literal: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :,.-_/=|()")

    static func isPlain(_ format: String) -> Bool {
        var rest = format[...]
        while let c = rest.first {
            if literal.contains(c) {
                rest = rest.dropFirst()
            } else if c == "\\", let next = rest.dropFirst().first, "nrt".contains(next) {
                rest = rest.dropFirst(2)
            } else if rest.hasPrefix("%{"), let close = rest.firstIndex(of: "}"),
                      variables.contains(String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close])) {
                rest = rest[rest.index(after: close)...]
            } else {
                return false
            }
        }
        return true
    }
}
