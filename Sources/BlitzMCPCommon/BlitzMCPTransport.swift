import Darwin
import Foundation

/// One request per local connection. Retry connection establishment only; once
/// connected, any failure is ambiguous and must never replay the request.
public enum BlitzMCPTransport {
    public enum Failure: LocalizedError {
        case unavailable, invalidPath, outcomeUnknown
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "Cannot connect to Blitz Neo. Is it running?"
            case .invalidPath: return "Blitz Neo MCP socket path is invalid."
            case .outcomeUnknown: return "Connection lost after sending began. Outcome unknown; reconcile the operation before retrying."
            }
        }
    }

    public static func send(_ request: String, socketPath: String, startupTimeout: TimeInterval,
                            responseTimeout: TimeInterval, expectsResponse: Bool = true) throws -> String? {
        let fd = try connect(socketPath, timeout: startupTimeout)
        defer { Darwin.close(fd) }
        let deadline = Date().addingTimeInterval(responseTimeout)
        let data = Data((request + "\n").utf8)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard Date() < deadline else { throw Failure.outcomeUnknown }
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    try wait(fd, for: Int16(POLLOUT), deadline: deadline)
                    continue
                }
                guard count > 0 else { throw Failure.outcomeUnknown }
                offset += count
            }
        }
        guard expectsResponse else { return nil }
        var response = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while Date() < deadline {
            // Read before polling so a closed peer's already-buffered reply is
            // drained. Do not change socket options after the peer has closed:
            // macOS may reject setsockopt with EINVAL despite readable data.
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                try wait(fd, for: Int16(POLLIN), deadline: deadline)
                continue
            }
            guard count > 0 else { throw Failure.outcomeUnknown }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= 16_777_216 else { throw Failure.outcomeUnknown }
            if let newline = response.firstIndex(of: 10) {
                guard let text = String(data: response.prefix(upTo: newline), encoding: .utf8), !text.isEmpty else {
                    throw Failure.outcomeUnknown
                }
                return text
            }
        }
        throw Failure.outcomeUnknown
    }

    private static func connect(_ path: String, timeout: TimeInterval) throws -> Int32 {
        var address = sockaddr_un()
        let length = path.utf8.count
        guard length > 0, length < MemoryLayout.size(ofValue: address.sun_path), !path.utf8.contains(0) else {
            throw Failure.invalidPath
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withCString { source in destination.copyBytes(from: UnsafeRawBufferPointer(start: source, count: length + 1)) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.unavailable }
            var noSignal: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                Darwin.close(fd); throw Failure.unavailable
            }
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                Darwin.close(fd); throw Failure.unavailable
            }
            let addressLength = socklen_t(address.sun_len)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addressLength) }
            }
            var code = connected == 0 ? 0 : errno
            if code == EINPROGRESS || code == EALREADY {
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                var pollResult: Int32
                repeat {
                    let remaining = max(0, min(deadline.timeIntervalSinceNow * 1000, Double(Int32.max)))
                    pollResult = poll(&descriptor, 1, Int32(remaining.rounded(.up)))
                } while pollResult < 0 && errno == EINTR && Date() < deadline
                if pollResult > 0 {
                    var socketError: Int32 = 0
                    var size = socklen_t(MemoryLayout<Int32>.size)
                    code = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 ? socketError : errno
                } else { code = ETIMEDOUT }
            }
            if code == 0 {
                // Keep this private connection nonblocking. send/read use poll
                // with one deadline, without resetting options on a closed peer.
                return fd
            }
            Darwin.close(fd)
            guard [ENOENT, ECONNREFUSED, EAGAIN, ETIMEDOUT, ECONNRESET, EINTR].contains(code), Date() < deadline else {
                throw Failure.unavailable
            }
            usleep(50_000)
        } while Date() < deadline
        throw Failure.unavailable
    }

    private static func wait(_ fd: Int32, for event: Int16, deadline: Date) throws {
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let remaining = max(1, min(deadline.timeIntervalSinceNow * 1000, Double(Int32.max)))
            let result = poll(&descriptor, 1, Int32(remaining.rounded(.up)))
            if result < 0 && errno == EINTR { continue }
            guard result > 0, descriptor.revents & Int16(POLLNVAL) == 0 else { throw Failure.outcomeUnknown }
            // HUP can arrive together with unread bytes. Let read drain them;
            // only EOF before the newline makes the response ambiguous.
            if descriptor.revents & (event | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
        }
        throw Failure.outcomeUnknown
    }
}
