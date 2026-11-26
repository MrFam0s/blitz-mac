import Darwin
import Testing
@testable import Blitz

struct MCPServerResponseTests {
    @Test func disconnectedClientDoesNotInterruptNextResponse() async {
        await #expect(processExitsWith: .success) {
            // Exercise the app's actual reply writer in an isolated process.
            signal(SIGPIPE, SIG_DFL)
            var signals = sigset_t()
            sigemptyset(&signals)
            sigaddset(&signals, SIGPIPE)
            try #require(pthread_sigmask(SIG_UNBLOCK, &signals, nil) == 0)

            var first = [Int32](repeating: -1, count: 2)
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &first) == 0)
            defer { Darwin.close(first[0]) }
            Darwin.close(first[1])
            do {
                try MCPServerService.writeResponse("first", to: first[0])
                Issue.record("A disconnected client must produce a socket error")
            } catch MCPServerService.MCPError.writeFailed(let code) {
                #expect(code == EPIPE || code == ECONNRESET || code == ENOTCONN)
            }

            var next = [Int32](repeating: -1, count: 2)
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &next) == 0)
            defer { Darwin.close(next[0]); Darwin.close(next[1]) }
            try MCPServerService.writeResponse("second", to: next[0])
            try #require(shutdown(next[0], SHUT_WR) == 0)
            let expected = Array("second\n".utf8)
            var bytes = [UInt8](repeating: 0, count: expected.count)
            try #require(Darwin.recv(next[1], &bytes, expected.count, MSG_WAITALL) == expected.count)
            #expect(bytes == expected)
        }
    }
}
