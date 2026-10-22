import Foundation

/// A JSON value that keeps object key order and the original text of numbers, so that rewriting a
/// user's config only changes what we touched.
public indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    /// The number as written in the source, e.g. "10" or "1.5e3".
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public static func int(_ value: Int) -> JSONValue { .number(String(value)) }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let text) = self { return Double(text) }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let text) = self else { return nil }
        return Int(text) ?? Double(text).flatMap { $0.isFinite ? Int(exactly: $0.rounded(.towardZero)) : nil }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }
}

public struct JSONObject: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var key: String
        public var value: JSONValue

        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    public var entries: [Entry]

    public init(_ entries: [Entry] = []) {
        self.entries = entries
    }

    public init(_ pairs: KeyValuePairs<String, JSONValue>) {
        self.entries = pairs.map { Entry(key: $0.key, value: $0.value) }
    }

    public var keys: [String] { entries.map(\.key) }

    /// Setting an existing key keeps its position; a new key is appended; `nil` removes it.
    public subscript(key: String) -> JSONValue? {
        get { entries.last(where: { $0.key == key })?.value }
        set {
            if let newValue {
                if let index = entries.lastIndex(where: { $0.key == key }) {
                    entries[index].value = newValue
                } else {
                    entries.append(Entry(key: key, value: newValue))
                }
            } else {
                entries.removeAll { $0.key == key }
            }
        }
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public var offset: Int
    public var message: String
    public var description: String { "JSON error at byte \(offset): \(message)" }
}

extension JSONValue {
    public init(parsing data: Data) throws {
        var parser = JSONParser(bytes: [UInt8](data))
        self = try parser.parseDocument()
    }

    public init(parsing text: String) throws {
        try self.init(parsing: Data(text.utf8))
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        // Skip a UTF-8 byte order mark.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    }

    mutating func parseDocument() throws -> JSONValue {
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw error("unexpected trailing characters") }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < 512 else { throw error("nesting too deep") }
        skipWhitespace()
        guard index < bytes.count else { throw error("unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw error("unexpected character")
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if peek(UInt8(ascii: "}")) { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard peek(UInt8(ascii: "\"")) else { throw error("expected object key") }
            let key = try parseString()
            skipWhitespace()
            guard peek(UInt8(ascii: ":")) else { throw error("expected ':'") }
            index += 1
            object.entries.append(.init(key: key, value: try parseValue(depth: depth + 1)))
            skipWhitespace()
            if peek(UInt8(ascii: ",")) { index += 1; continue }
            if peek(UInt8(ascii: "}")) { index += 1; return .object(object) }
            throw error("expected ',' or '}'")
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        var array: [JSONValue] = []
        skipWhitespace()
        if peek(UInt8(ascii: "]")) { index += 1; return .array(array) }
        while true {
            array.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            if peek(UInt8(ascii: ",")) { index += 1; continue }
            if peek(UInt8(ascii: "]")) { index += 1; return .array(array) }
            throw error("expected ',' or ']'")
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { throw error("unterminated escape") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalar), bytes[index...].starts(with: [UInt8(ascii: "\\"), UInt8(ascii: "u")]) {
                        index += 2
                        let low = try parseHex4()
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                    buffer.append(contentsOf: Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "\u{FFFD}").utf8))
                default:
                    throw error("invalid escape")
                }
            case 0x00..<0x20:
                throw error("control character in string")
            default:
                buffer.append(byte)
            }
        }
        throw error("unterminated string")
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
            throw error("invalid \\u escape")
        }
        index += 4
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        if peek(UInt8(ascii: "-")) { index += 1 }
        while index < bytes.count, "0123456789.eE+-".utf8.contains(bytes[index]) { index += 1 }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard Double(text) != nil else { throw error("invalid number") }
        return .number(text)
    }

    private mutating func expect(_ literal: String) throws {
        let utf8 = Array(literal.utf8)
        guard bytes[index...].starts(with: utf8) else { throw error("expected \(literal)") }
        index += utf8.count
    }

    private func peek(_ byte: UInt8) -> Bool {
        index < bytes.count && bytes[index] == byte
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private func error(_ message: String) -> JSONParseError {
        JSONParseError(offset: index, message: message)
    }
}

// MARK: - Printing

extension JSONValue {
    /// Single-line JSON, suitable for NDJSON.
    public var compactText: String {
        var output = ""
        write(to: &output, indent: nil, level: 0)
        return output
    }

    /// Pretty-printed JSON with `indent` spaces, the style most agent configs use.
    public func formatted(indent: Int = 2) -> String {
        var output = ""
        write(to: &output, indent: indent, level: 0)
        return output + "\n"
    }

    private func write(to output: inout String, indent: Int?, level: Int) {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let text): output += text
        case .string(let value): JSONValue.writeString(value, to: &output)
        case .array(let values):
            guard !values.isEmpty else { output += "[]"; return }
            output += "["
            for (offset, value) in values.enumerated() {
                if offset > 0 { output += "," }
                JSONValue.newline(&output, indent: indent, level: level + 1)
                value.write(to: &output, indent: indent, level: level + 1)
            }
            JSONValue.newline(&output, indent: indent, level: level)
            output += "]"
        case .object(let object):
            guard !object.entries.isEmpty else { output += "{}"; return }
            output += "{"
            for (offset, entry) in object.entries.enumerated() {
                if offset > 0 { output += "," }
                JSONValue.newline(&output, indent: indent, level: level + 1)
                JSONValue.writeString(entry.key, to: &output)
                output += indent == nil ? ":" : ": "
                entry.value.write(to: &output, indent: indent, level: level + 1)
            }
            JSONValue.newline(&output, indent: indent, level: level)
            output += "}"
        }
    }

    private static func newline(_ output: inout String, indent: Int?, level: Int) {
        guard let indent else { return }
        output += "\n" + String(repeating: " ", count: indent * level)
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(elements.map { JSONObject.Entry(key: $0.0, value: $0.1) }))
    }
    public init(nilLiteral: ()) { self = .null }
}
