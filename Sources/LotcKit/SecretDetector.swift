import Foundation

/// Spots text shaped like a credential. A match only ever sends a request to the permission window,
/// so it errs towards seeing secrets that are not there.
public enum SecretDetector {
    /// What the first secret-shaped run in `text` looks like, such as "an AWS access key id"; nil when none.
    public static func firstMatch(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for shape in shapes {
            for match in shape.pattern.matches(in: text, range: range) {
                guard let found = Range(match.range(at: match.numberOfRanges - 1), in: text) else { continue }
                if shape.accepts(String(text[found])) { return shape.name }
            }
        }
        return nil
    }

    private struct Shape {
        let name: String
        let pattern: NSRegularExpression
        /// A second look at the matched run (the last capture group), for shapes a pattern alone over-reads.
        var accepts: (String) -> Bool = { _ in true }

        init(_ name: String, _ pattern: String, accepts: @escaping (String) -> Bool = { _ in true }) {
            self.name = name
            self.pattern = try! NSRegularExpression(pattern: pattern)
            self.accepts = accepts
        }
    }

    private static let shapes: [Shape] = [
        Shape("an AWS access key id", #"(?<![A-Z0-9])(?:AKIA|ASIA|ABIA|ACCA|AGPA|AIDA|AIPA|ANPA|ANVA|AROA|APKA)[A-Z0-9]{16}(?![A-Z0-9])"#),
        Shape("a key starting sk-", #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}"#),
        Shape("a Stripe key", #"(?<![A-Za-z0-9])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#),
        Shape("a GitHub token", #"(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#),
        Shape("a Slack token", #"(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{10,}"#),
        Shape("a GitLab token", #"(?<![A-Za-z0-9])glpat-[A-Za-z0-9_-]{20,}"#),
        Shape("a Google API key", #"(?<![A-Za-z0-9])AIza[A-Za-z0-9_-]{30,}"#),
        Shape("an npm token", #"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{30,}"#),
        Shape("a JWT", #"eyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"#),
        Shape("a PEM block", #"-----BEGIN [A-Z0-9 ]+-----"#),
        // Prose says "basic authentication"; a credential has a digit or base64 padding in it.
        Shape("a Bearer or Basic credential", #"(?i)\b(?:bearer|basic)\s+([A-Za-z0-9._~+/-]{12,}=*)"#,
              accepts: { $0.contains { $0.isNumber || $0 == "=" || $0 == "+" || $0 == "/" } }),
        Shape("a password=value pair",
              #"(?i)(?<![A-Za-z0-9])(?:password|passwd|pwd|passphrase|secret|client_secret|api[_-]?key|access[_-]?key|private[_-]?key|token|access_token|auth[_-]?token)\s*[=:]\s*[^\s&]+"#),
        Shape("a long hex string", #"(?<![A-Fa-f0-9])([A-Fa-f0-9]{32,})(?![A-Fa-f0-9])"#,
              accepts: { $0.contains(where: \.isNumber) && $0.contains(where: \.isLetter) }),
        Shape("a long random-looking string", #"(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{32,}={0,2})"#,
              accepts: looksRandom),
    ]

    /// Upper case, lower case and digits, spread out as evenly as a key's characters are.
    static func looksRandom(_ run: String) -> Bool {
        guard run.contains(where: \.isUppercase), run.contains(where: \.isLowercase), run.contains(where: \.isNumber)
        else { return false }
        return entropy(run) >= 4.3
    }

    /// Shannon entropy in bits per character.
    static func entropy(_ text: String) -> Double {
        let counts = Dictionary(grouping: text, by: { $0 }).mapValues(\.count)
        let total = Double(text.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }
}
