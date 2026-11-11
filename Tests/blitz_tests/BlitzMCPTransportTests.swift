import Darwin
import Foundation
import Testing
import BlitzMCPCommon

struct BlitzMCPTransportTests {
    @Test(arguments: [true, false])
    func largeUTF8ReplySurvivesImmediatePeerClose(fragmented: Bool) async throws {
        let path = "/tmp/blitz-large-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withCString { destination.copyBytes(from: UnsafeRawBufferPointer(start: $0, count: path.utf8.count + 1)) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(Darwin.listen(listener, 2) == 0)
        let response = "{\"description\":\"" + String(repeating: "üÖ💡—ß", count: fragmented ? 30_000 : 4_000) + "\"}"
        let server = Task.detached {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            // The unfragmented reply fits in the sender's buffer. Closing right
            // after write leaves bytes to drain from a socket whose peer is gone.
            var sendBuffer: Int32 = 262_144
            _ = setsockopt(client, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.read(client, &buffer, buffer.count)
            let data = Data((response + "\n").utf8)
            data.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    // The other fixture splits Unicode scalars across chunks.
                    let chunk = fragmented ? min(4093, raw.count - sent) : raw.count - sent
                    let count = Darwin.write(client, raw.baseAddress!.advanced(by: sent), chunk)
                    guard count > 0 else { return }
                    sent += count
                }
            }
        }
        let received = try BlitzMCPTransport.send("{\"method\":\"tools/list\"}", socketPath: path,
            startupTimeout: 2, responseTimeout: 3)
        await server.value
        #expect(received == response)
    }

    @Test func saturatedSocketQueueRespectsStartupDeadline() async throws {
        let path = "/tmp/blitz-backlog-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        var queued: [Int32] = []
        defer {
            queued.forEach { Darwin.close($0) }
            Darwin.close(listener)
            unlink(path)
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withCString { destination.copyBytes(from: UnsafeRawBufferPointer(start: $0, count: path.utf8.count + 1)) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(Darwin.listen(listener, 1) == 0)
        try #require(fcntl(listener, F_SETFL, O_NONBLOCK) == 0)
        var encounteredFullQueue = false
        for _ in 0..<32 {
            let client = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(client >= 0)
            guard fcntl(client, F_SETFL, O_NONBLOCK) == 0 else {
                Darwin.close(client)
                Issue.record("Could not configure backlog fixture")
                return
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected == 0 { queued.append(client) }
            else if errno == EINPROGRESS || errno == EALREADY {
                encounteredFullQueue = true
                queued.append(client)
            } else {
                encounteredFullQueue = true
                Darwin.close(client)
            }
        }
        try #require(!queued.isEmpty && encounteredFullQueue)
        // Unstick the original blocking-connect implementation after one second
        // so this regression fails by elapsed time rather than hanging the suite.
        let drain = Task.detached {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            while true {
                let client = Darwin.accept(listener, nil, nil)
                guard client >= 0 else { return }
                Darwin.close(client)
            }
        }
        let started = ContinuousClock.now
        #expect(throws: BlitzMCPTransport.Failure.self) {
            try BlitzMCPTransport.send("{}", socketPath: path,
                startupTimeout: 0.15, responseTimeout: 0.15)
        }
        let elapsed = ContinuousClock.now - started
        drain.cancel()
        await drain.value
        #expect(elapsed < .milliseconds(800))
    }

    @Test(arguments: [true, false])
    func actualSocketNeverReplaysAfterServerConsumesRequest(reply: Bool) async throws {
        let path = "/tmp/blitz-transport-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withCString { destination.copyBytes(from: UnsafeRawBufferPointer(start: $0, count: path.utf8.count + 1)) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(Darwin.listen(listener, 2) == 0)
        let server = Task.detached { () -> Int in
            var wait = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&wait, 1, 2000) == 1 else { return 0 }
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return 0 }
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.read(client, &buffer, buffer.count)
            if reply {
                let response = Data("{\"received\":true}\n".utf8)
                response.withUnsafeBytes { _ = Darwin.write(client, $0.baseAddress, $0.count) }
            }
            Darwin.close(client) // Lost reply must not cause a second request.
            wait.revents = 0
            if poll(&wait, 1, 500) == 1 {
                let duplicate = Darwin.accept(listener, nil, nil)
                if duplicate >= 0 { Darwin.close(duplicate); return 2 }
            }
            return 1
        }
        if reply {
            #expect(try BlitzMCPTransport.send("{\"method\":\"test\"}", socketPath: path,
                startupTimeout: 2, responseTimeout: 1) == "{\"received\":true}")
        } else {
            #expect(throws: BlitzMCPTransport.Failure.self) {
                try BlitzMCPTransport.send("{\"method\":\"test\"}", socketPath: path,
                    startupTimeout: 2, responseTimeout: 1)
            }
        }
        #expect(await server.value == 1)
    }
}
