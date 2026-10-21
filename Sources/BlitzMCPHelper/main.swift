// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import BlitzMCPCommon
import Darwin
import Foundation

@main
struct BlitzMCPHelper {
    private struct RequestMetadata {
        let expectsResponse: Bool
        let id: Any
        let startupTimeout: TimeInterval
        let responseTimeout: TimeInterval
    }

    private enum HelperError: LocalizedError {
        case bridgeUnavailable
        case responseTimeout
        case emptyResponse
        case invalidSocketPath
        case socketCreateFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .bridgeUnavailable:
                return "Cannot connect to Blitz Neo. Is it running?"
            case .responseTimeout:
                return "Timed out waiting for a response from Blitz Neo."
            case .emptyResponse:
                return "Blitz Neo returned an empty MCP response."
            case .invalidSocketPath:
                return "Blitz Neo MCP socket path is invalid."
            case .socketCreateFailed:
                return "Failed to open the Blitz Neo MCP socket."
            case .writeFailed:
                return "Failed to send the MCP request to Blitz Neo."
            }
        }
    }

    static func main() async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                try handleLine(String(line))
            }
        } catch {
            log("MCP helper stopped: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func handleLine(_ line: String) throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let metadata = parseRequestMetadata(trimmed)

        do {
            if let response = try sendRequest(trimmed, metadata: metadata) {
                try writeLine(response, to: STDOUT_FILENO)
            }
        } catch {
            if metadata.expectsResponse {
                let response = errorResponse(id: metadata.id, message: error.localizedDescription)
                try writeLine(response, to: STDOUT_FILENO)
            } else {
                log("Notification failed: \(error.localizedDescription)")
            }
        }
    }

    private static func parseRequestMetadata(_ line: String) -> RequestMetadata {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RequestMetadata(expectsResponse: true, id: NSNull(), startupTimeout: 10, responseTimeout: 30)
        }

        let method = json["method"] as? String ?? ""
        return RequestMetadata(
            expectsResponse: json["id"] != nil,
            id: json["id"] ?? NSNull(),
            startupTimeout: method == "initialize" ? 30 : 10,
            responseTimeout: method == "initialize" ? 30 : 300
        )
    }

    private static func sendRequest(_ line: String, metadata: RequestMetadata) throws -> String? {
        let deadline = Date().addingTimeInterval(metadata.startupTimeout)
        let socketPath = BlitzMCPTransportPaths.socket.path

        while true {
            do {
                return try sendRequestOnce(
                    line,
                    expectsResponse: metadata.expectsResponse,
                    responseTimeout: metadata.responseTimeout,
                    socketPath: socketPath
                )
            } catch HelperError.bridgeUnavailable {
                guard Date() < deadline else { throw HelperError.bridgeUnavailable }
                usleep(250_000)
            } catch let error as POSIXError where shouldRetry(error.code) {
                guard Date() < deadline else { throw HelperError.bridgeUnavailable }
                usleep(250_000)
            } catch {
                throw error
            }
        }
    }

    private static func sendRequestOnce(
        _ line: String,
        expectsResponse: Bool,
        responseTimeout: TimeInterval,
        socketPath: String
    ) throws -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperError.socketCreateFailed }
        defer { Darwin.close(fd) }

        var timeout = timeval(
            tv_sec: Int(responseTimeout.rounded(.up)),
            tv_usec: 0
        )
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var address = try makeSocketAddress(path: socketPath)
        let addressLength = socklen_t(address.sun_len)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, addressLength)
            }
        }
        guard connectResult == 0 else {
            throw mapConnectError(errno)
        }

        try writeLine(line, to: fd)
        guard expectsResponse else { return nil }

        guard let response = try readLine(from: fd) else {
            throw HelperError.emptyResponse
        }
        return response
    }

    private static func shouldRetry(_ code: POSIXErrorCode) -> Bool {
        switch code {
        case .ENOENT, .ECONNREFUSED, .EAGAIN, .ETIMEDOUT, .ECONNRESET:
            return true
        default:
            return false
        }
    }

    private static func mapConnectError(_ code: Int32) -> Error {
        guard let posixCode = POSIXErrorCode(rawValue: code) else {
            return HelperError.bridgeUnavailable
        }
        if shouldRetry(posixCode) {
            return POSIXError(posixCode)
        }
        return HelperError.bridgeUnavailable
    }

    private static func makeSocketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let pathLength = path.utf8.count
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1

        guard pathLength <= maxPathLength else {
            throw HelperError.invalidSocketPath
        }

        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)

        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withCString { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(start: source, count: pathLength + 1))
            }
        }

        return address
    }

    private static func readLine(from fd: Int32) throws -> String? {
        var data = Data()
        var byte: UInt8 = 0

        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 {
                return data.isEmpty ? nil : String(data: data, encoding: .utf8)
            }
            if count < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    throw HelperError.responseTimeout
                }
                throw HelperError.bridgeUnavailable
            }
            if byte == 0x0A {
                return String(data: data, encoding: .utf8)
            }
            data.append(byte)
        }
    }

    private static func errorResponse(id: Any, message: String) -> String {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": -32000,
                "message": message
            ] as [String: Any]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Unknown Blitz Neo MCP error."}}"#
        }
        return json
    }

    private static func log(_ message: String) {
        try? writeLine(message, to: STDERR_FILENO)
    }

    private static func writeLine(_ line: String, to fd: Int32) throws {
        let data = Data((line + "\n").utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < rawBuffer.count {
                let nextPointer = baseAddress.advanced(by: bytesWritten)
                let result = Darwin.write(fd, nextPointer, rawBuffer.count - bytesWritten)
                if result < 0 {
                    throw HelperError.writeFailed
                }
                bytesWritten += result
            }
        }
    }
}
