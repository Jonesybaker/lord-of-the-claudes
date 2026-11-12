import Darwin
import Foundation

public enum LotcSocket {
    /// `LOTC_SOCKET` moves it, so a test build of the app cannot collide with the installed one.
    public static var path: String {
        if let override = ProcessInfo.processInfo.environment["LOTC_SOCKET"], !override.isEmpty { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LordOfTheClaudes/lotc.sock").path
    }
}

public enum LotcSocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case nobodyListening(String)
    case alreadyServed(String)
    case closed
    case timedOut
    case malformed
    case system(call: String, errno: Int32)

    public var description: String {
        switch self {
        case .pathTooLong(let path): return "socket path is too long for macOS: \(path)"
        case .nobodyListening(let path): return "nothing is listening on \(path)"
        case .alreadyServed(let path): return "another process is already answering on \(path)"
        case .closed: return "the other end closed the connection"
        case .timedOut: return "timed out"
        case .malformed: return "the other end sent something that is not a lotc message"
        case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// A connected Unix socket carrying one JSON value per line.
/// Used by one thread at a time; `@unchecked` because it is handed from thread to thread in turn.
public final class LineConnection: @unchecked Sendable {
    public let fd: Int32
    private var unread = Data()
    private var isClosed = false

    init(adopting fd: Int32) {
        self.fd = fd
        // Writing to a client that has gone would otherwise kill the whole process with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func connect(to path: String) throws -> LineConnection {
        var address = try unixAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LotcSocketError.system(call: "socket", errno: errno) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw LotcSocketError.nobodyListening(path)
        }
        return LineConnection(adopting: fd)
    }

    public func send<Value: Encodable>(_ value: Value) throws {
        var data = try JSONEncoder().encode(value)
        data.append(UInt8(ascii: "\n"))
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw LotcSocketError.closed
                }
                offset += written
            }
        }
    }

    /// Reads one line and decodes it, waiting at most `timeout` seconds for all of it.
    public func receive<Value: Decodable>(_ type: Value.Type, timeout: TimeInterval) throws -> Value {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = unread.firstIndex(of: UInt8(ascii: "\n")) {
                let line = unread[unread.startIndex..<newline]
                unread.removeSubrange(unread.startIndex...newline)
                guard let value = try? JSONDecoder().decode(Value.self, from: line) else { throw LotcSocketError.malformed }
                return value
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw LotcSocketError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 3600) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                throw LotcSocketError.system(call: "poll", errno: errno)
            }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { throw LotcSocketError.closed }
            unread.append(contentsOf: chunk[0..<count])
            guard unread.count < 32 * 1024 * 1024 else { throw LotcSocketError.malformed }
        }
    }

    /// True if the other end hangs up within `timeout` seconds.
    /// A client sends nothing after its request, so anything readable means it has gone.
    public func hasHungUp(within timeout: TimeInterval) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return false }
        var byte: UInt8 = 0
        let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if count == 0 { return true }
        if count < 0 { return errno != EAGAIN && errno != EINTR }
        // Stray bytes: drop them so the next poll does not return at once.
        var sink = [UInt8](repeating: 0, count: 4096)
        _ = recv(fd, &sink, sink.count, MSG_DONTWAIT)
        return false
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }
}

/// The app's end: a listening Unix socket only this user can open.
public final class LineListener: @unchecked Sendable {
    public let path: String
    private let fd: Int32

    /// Takes over a socket file left behind by a crash, but never one another process still answers on.
    public init(path: String) throws {
        self.path = path
        var address = try unixAddress(path)
        if FileManager.default.fileExists(atPath: path) {
            if let live = try? LineConnection.connect(to: path) {
                live.close()
                throw LotcSocketError.alreadyServed(path)
            }
            unlink(path)
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LotcSocketError.system(call: "socket", errno: errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw LotcSocketError.system(call: "bind", errno: code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw LotcSocketError.system(call: "listen", errno: code)
        }
    }

    /// Blocks until a client connects. Nil once the listener has been closed.
    public func accept() -> LineConnection? {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client >= 0 { return LineConnection(adopting: client) }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
    }

    public func close() {
        Darwin.close(fd)
        unlink(path)
    }
}

private func unixAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw LotcSocketError.pathTooLong(path) }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}
