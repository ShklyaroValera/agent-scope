import Foundation
import os
import Testing
@testable import AgentScopeKit

struct SocketTests {
    let directory: URL

    init() throws {
        // Short path: sockaddr_un holds 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/as-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var socketPath: String { directory.appending(path: "s.sock").path }

    @Test func clientDeliversLinesToServer() async throws {
        let received = OSAllocatedUnfairLock<[String]>(initialState: [])
        let server = SocketServer(path: socketPath) { line in
            received.withLock { $0.append(String(decoding: line, as: UTF8.self)) }
            return nil
        }
        try server.start()
        defer { server.stop() }

        #expect(SocketClient.send(Data("one\n".utf8), to: socketPath, timeout: 0.05))
        #expect(SocketClient.send(Data("two\nthree".utf8), to: socketPath, timeout: 0.05))
        for _ in 0..<100 where received.withLock({ $0.count }) < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received.withLock { $0.sorted() } == ["one", "three", "two"])
    }

    @Test func requestGetsResponse() throws {
        let server = SocketServer(path: socketPath) { line in
            StatusProtocol.isStatusRequest(line) ? Data("{\"ok\":true}\n".utf8) : nil
        }
        try server.start()
        defer { server.stop() }
        let response = SocketClient.request(StatusProtocol.request, to: socketPath, timeout: 1)
        #expect(response == Data("{\"ok\":true}\n".utf8))
    }

    @Test func sendFailsFastWithoutServer() {
        let started = Date()
        #expect(!SocketClient.send(Data("x\n".utf8), to: socketPath, timeout: 0.05))
        #expect(Date().timeIntervalSince(started) < 0.1)
    }

    @Test func secondServerRefusesToStart() throws {
        let first = SocketServer(path: socketPath) { _ in nil }
        try first.start()
        defer { first.stop() }
        let second = SocketServer(path: socketPath) { _ in nil }
        #expect(throws: SocketError.alreadyRunning) { try second.start() }
    }

    @Test func spoolAppendsAndDrains() {
        let spool = directory.appending(path: "spool.ndjson")
        Spool.append(Data("a\n".utf8), to: spool)
        Spool.append(Data("b\n".utf8), to: spool)
        #expect(Spool.drain(spool) == [Data("a".utf8), Data("b".utf8)])
        #expect(Spool.drain(spool).isEmpty)
    }
}
