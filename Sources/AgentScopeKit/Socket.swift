import Darwin
import Foundation

public enum SocketError: Error, Equatable {
    case pathTooLong
    case alreadyRunning
    case system(String, Int32)
}

private func makeAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { throw SocketError.pathTooLong }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

/// Waits until `fd` is ready for `events`, giving up at `deadline`.
private func wait(_ fd: Int32, for events: Int16, until deadline: Date) -> Bool {
    while true {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
        if result > 0 { return descriptor.revents & (events | Int16(POLLHUP)) != 0 }
        if result == 0 || errno != EINTR { return false }
    }
}

public enum SocketClient {
    /// Connects, writes `data`, closes. Returns false — without blocking past `timeout` (connect) or
    /// `writeTimeout` (everything) — when nobody listens or the write cannot finish.
    @discardableResult
    public static func send(_ data: Data, to path: String, timeout: TimeInterval, writeTimeout: TimeInterval? = nil) -> Bool {
        let start = Date()
        guard let fd = connect(path, deadline: start.addingTimeInterval(timeout)) else { return false }
        defer { close(fd) }
        return write(data, to: fd, deadline: start.addingTimeInterval(max(timeout, writeTimeout ?? timeout)))
    }

    /// Sends one request line and returns everything the server writes back before closing.
    public static func request(_ data: Data, to path: String, timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        guard let fd = connect(path, deadline: deadline) else { return nil }
        defer { close(fd) }
        guard write(data, to: fd, deadline: deadline) else { return nil }
        shutdown(fd, SHUT_WR)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while wait(fd, for: Int16(POLLIN), until: deadline) {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { response.append(buffer, count: count) } else if count == 0 || errno != EAGAIN { break }
        }
        return response
    }

    private static func connect(_ path: String, deadline: Date) -> Int32? {
        guard var address = try? makeAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return fd }
        if errno == EINPROGRESS || errno == EAGAIN, wait(fd, for: Int16(POLLOUT), until: deadline) {
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 { return fd }
        }
        close(fd)
        return nil
    }

    private static func write(_ data: Data, to fd: Int32, deadline: Date) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EAGAIN || errno == EINTR {
                    guard wait(fd, for: Int16(POLLOUT), until: deadline) else { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }
}

/// Listens on a Unix domain socket and hands every received line to `handler`. When the handler returns
/// data, it is written back and the connection is closed (used by `agentscope status`).
public final class SocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) -> Data?

    private let path: String
    private let handler: Handler
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    /// Serial: events from different hook processes are handled in arrival order (a late "started" can
    /// otherwise land after its "finished"). Hooks send one small line each, so nothing waits long.
    private let connections = DispatchQueue(label: "agentscope.socket.connections")

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        var address = try makeAddress(path)
        if SocketClient.send(Data(), to: path, timeout: 0.05) { throw SocketError.alreadyRunning }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let code = errno; close(fd); throw SocketError.system("bind", code) }
        chmod(path, 0o600)
        guard listen(fd, 128) == 0 else { let code = errno; close(fd); throw SocketError.system("listen", code) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "agentscope.socket.accept"))
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listener >= 0 {
            unlink(path)
            listener = -1
        }
    }

    private func acceptPending() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            connections.async { [handler] in Self.serve(client, handler: handler) }
        }
    }

    private static func serve(_ fd: Int32, handler: Handler) {
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                pending.append(buffer, count: count)
            }
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = pending[(newline + 1)...]
                if !line.isEmpty, let response = handler(Data(line)) {
                    response.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
                    return
                }
            }
            if count <= 0 { break }
        }
        if !pending.isEmpty { _ = handler(Data(pending)) }
    }
}

/// Lines written while the app is not running; the app replays them on launch.
public enum Spool {
    public static let maxBytes = 20 * 1024 * 1024

    public static func append(_ line: Data, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Int(info.st_size) + line.count <= maxBytes else { return }
        _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    }

    /// Moves the spool aside so new hook calls start a fresh one. Read the claimed file with `read(_:)`
    /// a moment later: a hook that opened the spool just before the rename may still be writing to it.
    public static func claim(_ url: URL) -> URL? {
        let claimed = url.appendingPathExtension("draining")
        guard rename(url.path, claimed.path) == 0 || FileManager.default.fileExists(atPath: claimed.path) else { return nil }
        return claimed
    }

    /// Lines of a claimed spool, oldest first; deletes it.
    public static func read(_ claimed: URL) -> [Data] {
        defer { unlink(claimed.path) }
        guard let data = try? Data(contentsOf: claimed) else { return [] }
        return data.split(separator: 0x0A).map { Data($0) }
    }

    public static func drain(_ url: URL) -> [Data] {
        claim(url).map(read) ?? []
    }
}
