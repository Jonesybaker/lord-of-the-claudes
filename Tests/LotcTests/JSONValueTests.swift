import Testing
@testable import LotcKit

struct JSONValueTests {
    /// Laid out exactly as Claude Code writes settings.json: JSON.stringify(value, null, 2) plus a newline.
    static let settings = """
        {
          "permissions": {
            "defaultMode": "auto",
            "allow": [
              "Bash(git status)",
              "Read(//Users/mj/**)"
            ],
            "deny": []
          },
          "model": "opus",
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "~/.claude/hooks/stop.sh \\"quoted\\" \\\\ back",
                    "timeout": 30
                  }
                ]
              }
            ]
          },
          "statusLine": {},
          "ratio": 1.0,
          "big": 12345678901234567890,
          "exp": -2.5e-3,
          "flag": false,
          "nothing": null,
          "text": "tab\\tnewline\\ncontrol\\u0001 café 😀"
        }
        """

    @Test func roundTripsClaudeCodeSettingsByteForByte() throws {
        let value = try JSONValue(parsing: Self.settings)
        #expect(value.formatted() == Self.settings)
    }

    @Test func keepsKeyOrderAndNumberLiterals() throws {
        let value = try JSONValue(parsing: Self.settings)
        #expect(value.members?.map(\.key) == ["permissions", "model", "hooks", "statusLine", "ratio", "big", "exp", "flag", "nothing", "text"])
        #expect(value["ratio"] == .number("1.0"))
        #expect(value["big"] == .number("12345678901234567890"))
    }

    @Test func decodesEscapesAndSurrogatePairs() throws {
        let value = try JSONValue(parsing: #"{"a":"😀 é \/ \"x\""}"#)
        #expect(value["a"] == .string("😀 é / \"x\""))
    }

    @Test(arguments: ["", "{", #"{"a":}"#, "[1,]", "tru", #"{"a":1} x"#, "01x", #""unterminated"#, "-"])
    func rejectsMalformedJSON(_ text: String) {
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: text) }
    }

    @Test func setReplacesInPlaceAddsAtTheEndAndRemoves() throws {
        var value = try JSONValue(parsing: #"{"a":1,"b":2}"#)
        value.set("a", .string("x"))
        value.set("c", .bool(true))
        #expect(value.members?.map(\.key) == ["a", "b", "c"])
        #expect(value["a"] == .string("x"))
        value.set("b", nil)
        #expect(value.members?.map(\.key) == ["a", "c"])
    }

    @Test func emptyContainersStayOnOneLine() throws {
        #expect(try JSONValue(parsing: #"{"a":[],"b":{}}"#).formatted() == "{\n  \"a\": [],\n  \"b\": {}\n}")
    }
}
