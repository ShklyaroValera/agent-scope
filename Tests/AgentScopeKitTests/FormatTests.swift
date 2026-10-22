import Foundation
import Testing
@testable import AgentScopeKit

struct FormatTests {
    @Test(arguments: [
        (0.0, "0s"), (32, "32s"), (59.9, "59s"), (60, "1m"), (4 * 60 + 59, "4m"),
        (3600, "1h"), (3900, "1h 5m"), (86_400 * 2 + 5, "2d"), (-5, "0s"),
    ] as [(TimeInterval, String)])
    func elapsed(interval: TimeInterval, expected: String) {
        #expect(Format.elapsed(interval) == expected)
    }

    @Test(arguments: [
        (0, "0"), (999, "999"), (1284, "1\u{00A0}284"), (1_000_000, "1\u{00A0}000\u{00A0}000"), (-1284, "-1\u{00A0}284"),
    ])
    func count(value: Int, expected: String) {
        #expect(Format.count(value) == expected)
    }

    @Test(arguments: [
        (950, "950"), (1_000, "1K"), (12_400, "12.4K"), (999_949, "999.9K"), (999_950, "1M"), (3_100_000, "3.1M"),
    ])
    func tokens(value: Int, expected: String) {
        #expect(Format.tokens(value) == expected)
    }

    @Test func cost() {
        #expect(Format.cost(4.62) == "$4.62")
        #expect(Format.cost(0) == "$0.00")
    }

    @Test func percent() {
        #expect(Format.percent(0.62) == "62%")
        #expect(Format.percent(1.4) == "100%")
        #expect(Format.percent(-0.1) == "0%")
    }

    @Test func truncated() {
        #expect(Format.truncated("npm test", to: 60) == "npm test")
        let long = Format.truncated(String(repeating: "a", count: 80), to: 60)
        #expect(long.count == 60)
        #expect(long.hasSuffix("…"))
    }
}
