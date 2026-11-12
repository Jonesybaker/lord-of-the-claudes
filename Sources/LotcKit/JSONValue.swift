import Foundation

/// JSON that keeps object keys in the order they were written, so editing Claude Code's settings
/// leaves the rest of the file as it was, and a tool's input reads in the order Claude wrote it.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number exactly as written, so 1.0 stays 1.0 and long integers keep every digit.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])

    /// The value under `key` when this is an object; the last one wins, as in JavaScript.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.key == key }?.value
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var members: [JSONMember]? {
        if case .object(let members) = self { return members }
        return nil
    }

    /// Equal as JSON means it: object keys in any order, numbers by value.
    public func isEquivalent(to other: JSONValue) -> Bool {
        switch (self, other) {
        case (.number(let a), .number(let b)):
            return a == b || (Double(a) != nil && Double(a) == Double(b))
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.isEquivalent(to: $1) }
        case (.object(let a), .object(let b)):
            let keys = Set(a.map(\.key))
            return keys == Set(b.map(\.key)) && keys.allSatisfy { key in
                guard let mine = self[key], let theirs = other[key] else { return false }
                return mine.isEquivalent(to: theirs)
            }
        default:
            return self == other
        }
    }

    /// On an object: replaces `key` where it stands, adds it at the end if new, or removes it when `value` is nil.
    public mutating func set(_ key: String, _ value: JSONValue?) {
        guard case .object(var members) = self else { return }
        if let value {
            if let index = members.lastIndex(where: { $0.key == key }) {
                members[index].value = value
            } else {
                members.append(JSONMember(key, value))
            }
        } else {
            members.removeAll { $0.key == key }
        }
        self = .object(members)
    }
}

public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

// MARK: Reading

public struct JSONParseError: Error, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "\(reason) at byte \(offset)" }
}

extension JSONValue {
    public init(parsing text: String) throws {
        var parser = JSONParser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        self = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.failure("unexpected text after the JSON") }
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0
    private var depth = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    func failure(_ reason: String) -> JSONParseError { JSONParseError(offset: index, reason: reason) }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func value() throws -> JSONValue {
        guard index < bytes.count else { throw failure("unexpected end of JSON") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try nested { try $0.object() }
        case UInt8(ascii: "["): return try nested { try $0.array() }
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
        default: throw failure("unexpected character")
        }
    }

    /// Deeply nested input would otherwise overflow the stack.
    private mutating func nested(_ parse: (inout JSONParser) throws -> JSONValue) throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 512 else { throw failure("JSON nested too deeply") }
        return try parse(&self)
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard index < bytes.count, bytes[index] == byte else { throw failure("expected \(Character(Unicode.Scalar(byte)))") }
        index += 1
    }

    private mutating func literal(_ word: String) throws {
        for byte in word.utf8 { try expect(byte) }
    }

    private mutating func object() throws -> JSONValue {
        try expect(UInt8(ascii: "{"))
        var members: [JSONMember] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            let key = try string()
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            skipWhitespace()
            members.append(JSONMember(key, try value()))
            skipWhitespace()
            guard index < bytes.count else { throw failure("unfinished object") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            try expect(UInt8(ascii: "}"))
            return .object(members)
        }
    }

    private mutating func array() throws -> JSONValue {
        try expect(UInt8(ascii: "["))
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try value())
            skipWhitespace()
            guard index < bytes.count else { throw failure("unfinished array") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            try expect(UInt8(ascii: "]"))
            return .array(items)
        }
    }

    private mutating func number() throws -> String {
        let start = index
        func digits() -> Int {
            let from = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            return index - from
        }
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard digits() > 0 else { throw failure("expected a digit") }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard digits() > 0 else { throw failure("expected a digit after the decimal point") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw failure("expected a digit in the exponent") }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func string() throws -> String {
        try expect(UInt8(ascii: "\""))
        var utf8: [UInt8] = []
        while true {
            guard index < bytes.count else { throw failure("unfinished string") }
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: utf8, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { throw failure("unfinished escape") }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(escaped)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                case UInt8(ascii: "u"): utf8.append(contentsOf: String(try unicodeEscape()).utf8)
                default: throw failure("unknown escape")
                }
            default:
                utf8.append(byte)
            }
        }
    }

    /// `\uXXXX`, joining a surrogate pair into one character.
    private mutating func unicodeEscape() throws -> Character {
        let first = try hex4()
        if (0xD800...0xDBFF).contains(first), index + 1 < bytes.count,
           bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
            let save = index
            index += 2
            let second = try hex4()
            if (0xDC00...0xDFFF).contains(second),
               let scalar = Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)) {
                return Character(scalar)
            }
            index = save
        }
        return Character(Unicode.Scalar(first) ?? "\u{FFFD}")
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count,
              let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw failure("bad \\u escape") }
        index += 4
        return value
    }
}

// MARK: Writing

extension JSONValue {
    /// Laid out as JavaScript's `JSON.stringify(value, null, 2)` does, which is how Claude Code writes its settings.
    public func formatted() -> String {
        var out = ""
        write(into: &out, level: 0)
        return out
    }

    private func write(into out: inout String, level: Int) {
        let indent = String(repeating: "  ", count: level)
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let literal): out += literal
        case .string(let value): out += Self.quoted(value)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (offset, item) in items.enumerated() {
                out += indent + "  "
                item.write(into: &out, level: level + 1)
                out += offset < items.count - 1 ? ",\n" : "\n"
            }
            out += indent + "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (offset, member) in members.enumerated() {
                out += indent + "  " + Self.quoted(member.key) + ": "
                member.value.write(into: &out, level: level + 1)
                out += offset < members.count - 1 ? ",\n" : "\n"
            }
            out += indent + "}"
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
