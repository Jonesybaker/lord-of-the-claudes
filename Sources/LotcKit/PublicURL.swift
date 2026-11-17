import Foundation

/// Whether a URL is a plain https address of a public web page, with nothing in it that signs in or
/// looks like a secret. Read strictly by hand rather than with a URL parser, so that what is checked is
/// exactly what the tool will be given: anything unusual is a reason to ask.
public enum PublicURL {
    /// Nil when the URL passes; otherwise why not, such as "the URL is http, not https".
    public static func problem(with url: String) -> String? {
        guard !url.isEmpty else { return "the URL is empty" }
        guard url.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            return "the URL has a space, a control character or a character outside plain ASCII"
        }
        guard url.lowercased().hasPrefix("https://") else {
            return url.lowercased().hasPrefix("http://") ? "the URL is http, not https" : "the URL is not https"
        }
        let rest = url.dropFirst("https://".count)
        let authority = String(rest.prefix { !"/?#".contains($0) })
        let afterAuthority = String(rest.dropFirst(authority.count))

        if authority.contains("@") { return "the URL carries a user name or password" }
        if authority.hasPrefix("[") { return "the host is an IP address" }
        if let odd = url.first(where: { "\\[]{}<>\"^`|".contains($0) }) {
            return "the URL has a \(odd) in it, which a plain address does not need"
        }
        guard !authority.isEmpty else { return "the URL has no host" }

        var host = authority
        if let colon = authority.lastIndex(of: ":") {
            host = String(authority[..<colon])
            if authority[authority.index(after: colon)...] != "443" { return "the URL names a port" }
        }
        if let problem = hostProblem(host.lowercased()) { return problem }

        if let name = credentialParameter(in: afterAuthority) {
            return "the URL carries a parameter named \(name)"
        }
        if afterAuthority.contains("%"), afterAuthority.removingPercentEncoding == nil {
            return "the URL has a malformed % escape"
        }
        let decoded = url.removingPercentEncoding ?? url
        if let secret = SecretDetector.firstMatch(in: url) ?? SecretDetector.firstMatch(in: decoded) {
            return "the URL has something that looks like \(secret)"
        }
        return nil
    }

    /// Names that resolve to this Mac whatever they are given, or spell out an IP address.
    static let loopbackServices = ["localtest.me", "lvh.me", "vcap.me", "nip.io", "sslip.io", "xip.io", "traefik.me", "local.gd"]
    static let localSuffixes = ["local", "internal", "localdomain", "lan", "home", "corp", "intranet", "arpa"]

    static func hostProblem(_ host: String) -> String? {
        guard !host.isEmpty else { return "the URL has no host" }
        if host.hasSuffix(".") { return "the host ends with a dot" }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let tld = labels.last else { return "the URL has no host" }
        if host == "localhost" || tld == "localhost" { return "the host is this Mac (localhost)" }
        let numeric = { (label: String) in !label.isEmpty && (label.allSatisfy(\.isASCIIDigit) || label.hasPrefix("0x")) }
        if numeric(tld) || labels.allSatisfy({ numeric($0) || $0.allSatisfy(\.isHexDigit) }) && labels.contains(where: numeric) {
            return "the host is an IP address"
        }
        guard labels.count >= 2 else { return "the host has no dot, so it is a name on the local network" }
        for label in labels {
            guard (1...63).contains(label.count), label.allSatisfy({ $0.isASCIIDigit || ("a"..."z").contains($0) || $0 == "-" }),
                  !label.hasPrefix("-"), !label.hasSuffix("-")
            else { return "the host is not a plain domain name" }
        }
        guard tld.count >= 2, tld.allSatisfy({ ("a"..."z").contains($0) }) || tld.hasPrefix("xn--") else {
            return "the host is not a public domain name"
        }
        if localSuffixes.contains(tld) || host.hasSuffix(".home.arpa") {
            return "the host is a local network name (.\(tld))"
        }
        if loopbackServices.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return "the host is a service that points back at this Mac or at an IP address"
        }
        // 127.0.0.1.example.com: some DNS services answer with the address the name spells out.
        let run = labels.reduce(into: (current: 0, longest: 0)) { run, label in
            run.current = label.allSatisfy(\.isASCIIDigit) && Int(label).map { $0 <= 255 } == true ? run.current + 1 : 0
            run.longest = max(run.longest, run.current)
        }
        if run.longest >= 4 { return "the host spells out an IP address" }
        return nil
    }

    /// Query, fragment and path parameter names that carry a credential.
    static let credentialNames: Set<String> = [
        "token", "key", "apikey", "api_key", "secret", "password", "passwd", "auth", "signature", "sig", "session",
        "sid", "jwt", "access_token", "code", "credential", "credentials", "pwd", "pass", "passphrase",
    ]
    static let credentialWords = ["token", "secret", "password", "passwd", "apikey", "signature", "credential", "session",
                                  "sessid", "jwt", "passphrase"]

    /// The first `name=` after the host whose name is credential-like, decoded; nil when none.
    static func credentialParameter(in afterAuthority: String) -> String? {
        for piece in afterAuthority.split(whereSeparator: { "?&;#/".contains($0) }) {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let raw = String(piece[..<equals]).replacingOccurrences(of: "+", with: " ")
            let name = raw.removingPercentEncoding ?? raw
            if isCredential(name) { return name }
        }
        return nil
    }

    static func isCredential(_ name: String) -> Bool {
        let lower = name.lowercased()
        if credentialNames.contains(lower) { return true }
        let parts = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if parts.contains(where: credentialNames.contains) { return true }
        return credentialWords.contains { lower.contains($0) }
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
