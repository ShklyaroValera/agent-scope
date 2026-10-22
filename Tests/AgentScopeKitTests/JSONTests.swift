import Foundation
import Testing
@testable import AgentScopeKit

struct JSONTests {
    @Test func roundTripKeepsKeyOrderAndNumberText() throws {
        let text = """
        {
          "zeta": 1,
          "alpha": [
            1.50,
            -2e3,
            true,
            null
          ],
          "nested": {
            "b": "x",
            "a": {}
          },
          "empty": []
        }

        """
        let value = try JSONValue(parsing: text)
        #expect(value.objectValue?.keys == ["zeta", "alpha", "nested", "empty"])
        #expect(value.formatted() == text)
    }

    @Test func escapesAndUnicode() throws {
        let value = try JSONValue(parsing: #"{"s":"a\"b\\c\n\té😀/ok","path":"\/usr"}"#)
        #expect(value["s"]?.stringValue == "a\"b\\c\n\té😀/ok")
        #expect(value["path"]?.stringValue == "/usr")
        #expect(value.compactText == #"{"s":"a\"b\\c\n\té😀/ok","path":"/usr"}"#)
    }

    @Test func rejectsInvalidInput() {
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: "{\"a\":}") }
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: "[1,2") }
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: "{} trailing") }
    }

    @Test func objectSubscriptKeepsPosition() {
        var object = JSONObject(["a": 1, "b": 2])
        object["a"] = 3
        object["c"] = 4
        object["b"] = nil
        #expect(object.keys == ["a", "c"])
        #expect(object["a"] == 3)
    }

    @Test func numberAccessors() throws {
        let value = try JSONValue(parsing: #"{"i":42,"d":1.5,"big":1e3}"#)
        #expect(value["i"]?.intValue == 42)
        #expect(value["d"]?.doubleValue == 1.5)
        #expect(value["big"]?.intValue == 1000)
    }
}
