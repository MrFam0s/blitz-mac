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
        case emptyResponse, writeFailed
        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "Blitz Neo returned an empty response. Reconcile before retrying."
            case .writeFailed: return "Could not write the MCP response. Reconcile before retrying."
            }
        }
    }

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            if arguments == ["--help"] || arguments == ["release", "--help"] {
                print(BlitzReleaseCLI.help)
                return
            }
            do {
                let invocation = try BlitzReleaseCLI.parse(arguments)
                let input: FileHandle
                if invocation.requestPath == "-" { input = .standardInput }
                else { input = try FileHandle(forReadingFrom: URL(fileURLWithPath: invocation.requestPath)) }
                defer { if invocation.requestPath != "-" { try? input.close() } }
                var data = Data()
                while let part = try input.read(upToCount: 65_536), !part.isEmpty {
                    data.append(part)
                    guard data.count <= 1_048_576 else { throw BlitzReleaseCLI.CLIError.oversizedRequest }
                }
                let id = UUID().uuidString
                let request = try BlitzReleaseCLI.request(invocation, data: data, id: id)
                guard let response = try sendRequest(request, metadata: parseRequestMetadata(request)) else {
                    throw HelperError.emptyResponse
                }
                let output = try BlitzReleaseCLI.output(response: response, id: id, tool: invocation.tool)
                print(output.json)
                if output.failed { exit(1) }
            } catch {
                log(error.localizedDescription)
                exit(1)
            }
            return
        }
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
        try BlitzMCPTransport.send(line, socketPath: BlitzMCPTransportPaths.socket.path,
            startupTimeout: metadata.startupTimeout, responseTimeout: metadata.responseTimeout,
            expectsResponse: metadata.expectsResponse)
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
                if result <= 0 {
                    throw HelperError.writeFailed
                }
                bytesWritten += result
            }
        }
    }
}
