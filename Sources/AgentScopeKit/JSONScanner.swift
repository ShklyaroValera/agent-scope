/// Finds the members of a top-level JSON object without decoding their values: one pass over the bytes,
/// skipping strings and nested containers. Used by the hook to filter payloads of any size quickly.
enum JSONScanner {
    struct Member {
        var key: String
        /// The key including its quotes.
        var keyRange: Range<Int>
        var value: Range<Int>
    }

    static func topLevelMembers(_ bytes: [UInt8]) -> [Member]? {
        var index = 0
        func skipWhitespace() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D || bytes[index] == 0x09 {
                index += 1
            }
        }
        func skipString() -> Bool {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return false }
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""): index += 1; return true
                default: index += 1
                }
            }
            return false
        }
        func skipValue() -> Bool {
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case UInt8(ascii: "\""):
                return skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while index < bytes.count {
                    switch bytes[index] {
                    case UInt8(ascii: "\""):
                        guard skipString() else { return false }
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 { index += 1; return true }
                    default: break
                    }
                    index += 1
                }
                return false
            default:
                let start = index
                while index < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) {
                    index += 1
                }
                return index > start
            }
        }

        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
        index += 1
        var members: [Member] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { return members }
        while true {
            skipWhitespace()
            let keyStart = index
            guard skipString() else { return nil }
            let keyRange = keyStart..<index
            guard let key = (try? JSONValue(parsing: String(decoding: bytes[keyRange], as: UTF8.self)))?.stringValue else { return nil }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            skipWhitespace()
            let valueStart = index
            guard skipValue() else { return nil }
            members.append(Member(key: key, keyRange: keyRange, value: valueStart..<index))
            skipWhitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { return members }
            return nil
        }
    }
}
