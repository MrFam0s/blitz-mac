// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Darwin
import Foundation

/// MCP server endpoint owned by the Blitz app.
/// Codex launches a separate stdio helper, and the helper forwards each JSON-RPC
/// request over a Unix domain socket to the running app.
actor MCPServerService {
    private var acceptSource: DispatchSourceRead?
    private var serverSocket: Int32 = -1
    private(set) var isRunning = false

    private let toolExecutor: MCPExecutor

    init(appState: AppState) {
        self.toolExecutor = MCPExecutor(appState: appState)

        Task { @MainActor in
            appState.toolExecutor = self.toolExecutor
        }
    }

    func start() async throws {
        guard !isRunning else { return }

        let socketFD = try createServerSocket()
        serverSocket = socketFD
        isRunning = true

        let source = DispatchSource.makeReadSource(
            fileDescriptor: socketFD,
            queue: DispatchQueue(label: "blitz.mcp.accept")
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.acceptPendingConnections()
            }
        }
        source.resume()
        acceptSource = source

        print("[MCP] Server listening on Unix socket \(BlitzPaths.mcpSocket.path)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil

        if serverSocket >= 0 {
            Darwin.close(serverSocket)
            serverSocket = -1
        }

        isRunning = false
        removeSocketFile()
    }

    private func createServerSocket() throws -> Int32 {
        removeSocketFile()

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw MCPError.socketCreationFailed
        }

        var address = try makeSocketAddress()
        let addressLength = socklen_t(address.sun_len)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(socketFD, sockaddrPointer, addressLength)
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw MCPError.bindFailed(code: errno)
        }

        guard Darwin.listen(socketFD, SOMAXCONN) == 0 else {
            Darwin.close(socketFD)
            throw MCPError.listenFailed(code: errno)
        }

        let currentFlags = fcntl(socketFD, F_GETFL, 0)
        if currentFlags >= 0 {
            _ = fcntl(socketFD, F_SETFL, currentFlags | O_NONBLOCK)
        }

        _ = chmod(BlitzPaths.mcpSocket.path, mode_t(0o600))
        return socketFD
    }

    private func acceptPendingConnections() async {
        while serverSocket >= 0 {
            let clientFD = Darwin.accept(serverSocket, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    return
                }
                print("[MCP] accept() failed: \(errno)")
                return
            }

            // Client sockets inherit O_NONBLOCK from the listening socket.
            // Reset to blocking so large responses (e.g. tools/list) don't
            // fail with EAGAIN when the send buffer fills.
            let flags = fcntl(clientFD, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)
            }

            Task.detached { [weak self] in
                await self?.handleConnection(clientFD)
            }
        }
    }

    private func handleConnection(_ clientFD: Int32) async {
        defer { Darwin.close(clientFD) }

        do {
            guard let line = try readLine(from: clientFD) else { return }
            if let response = await processMCPLine(line) {
                try writeLine(response, to: clientFD)
            }
        } catch {
            print("[MCP] Socket client failed: \(error.localizedDescription)")
        }
    }

    private func readLine(from fd: Int32) throws -> String? {
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var data = Data()
        var byte: UInt8 = 0

        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 {
                return data.isEmpty ? nil : String(data: data, encoding: .utf8)
            }
            if count < 0 {
                throw MCPError.readFailed(code: errno)
            }
            if byte == 0x0A {
                return String(data: data, encoding: .utf8)
            }
            data.append(byte)
        }
    }

    private func writeLine(_ line: String, to fd: Int32) throws {
        let data = Data((line + "\n").utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0

            while bytesWritten < rawBuffer.count {
                let pointer = baseAddress.advanced(by: bytesWritten)
                let result = Darwin.write(fd, pointer, rawBuffer.count - bytesWritten)
                if result < 0 {
                    throw MCPError.writeFailed(code: errno)
                }
                bytesWritten += result
            }
        }
    }

    private func makeSocketAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        let path = BlitzPaths.mcpSocket.path
        let pathLength = path.utf8.count
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1

        guard pathLength <= maxPathLength else {
            throw MCPError.invalidSocketPath
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

    private func removeSocketFile() {
        try? FileManager.default.removeItem(at: BlitzPaths.mcpSocket)
    }

    private func processMCPLine(_ line: String) async -> String? {
        guard let body = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return errorResponse(id: NSNull(), code: -32700, message: "Invalid MCP JSON.")
        }

        guard let methodName = json["method"] as? String else {
            return errorResponse(id: json["id"] ?? NSNull(), code: -32600, message: "Invalid MCP request.")
        }

        let id: Any = json["id"] ?? NSNull()
        let hasResponseID = json["id"] != nil
        let isNotification = !hasResponseID || methodName.hasPrefix("notifications/")
        let params = json["params"] as? [String: Any] ?? [:]

        let result: Any
        switch methodName {
        case "initialize":
            let clientVersion = params["protocolVersion"] as? String ?? "2024-11-05"
            result = [
                "protocolVersion": clientVersion,
                "capabilities": [
                    "tools": ["listChanged": false]
                ],
                "serverInfo": [
                    "name": "blitz-mcp",
                    "version": "1.0.0"
                ]
            ] as [String: Any]

        case "notifications/initialized":
            return nil

        case "tools/list":
            result = [
                "tools": MCPRegistry.allTools()
            ]

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let toolArgs = params["arguments"] as? [String: Any] ?? [:]
            do {
                result = try await toolExecutor.execute(name: toolName, arguments: toolArgs)
            } catch {
                return errorResponse(id: id, code: -32603, message: error.localizedDescription)
            }

        default:
            if isNotification { return nil }
            return errorResponse(id: id, code: -32601, message: "Unknown MCP method: \(methodName)")
        }

        if isNotification { return nil }

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let json = String(data: data, encoding: .utf8) else {
            return errorResponse(id: id, code: -32603, message: "Failed to encode MCP response.")
        }
        return json
    }

    private func errorResponse(id: Any, code: Int, message: String) -> String {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ] as [String: Any]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"MCP error."}}"#
        }
        return json
    }

    enum MCPError: Error, LocalizedError {
        case socketCreationFailed
        case bindFailed(code: Int32)
        case listenFailed(code: Int32)
        case invalidSocketPath
        case readFailed(code: Int32)
        case writeFailed(code: Int32)
        case unknownTool(String)
        case invalidToolArgs

        var errorDescription: String? {
            switch self {
            case .socketCreationFailed:
                return "Failed to create the Blitz Neo MCP socket."
            case .bindFailed(let code):
                return "Failed to bind Blitz Neo MCP socket (\(code))."
            case .listenFailed(let code):
                return "Failed to listen on Blitz Neo MCP socket (\(code))."
            case .invalidSocketPath:
                return "Invalid Blitz Neo MCP socket path."
            case .readFailed(let code):
                return "Failed to read from Blitz Neo MCP socket (\(code))."
            case .writeFailed(let code):
                return "Failed to write to Blitz Neo MCP socket (\(code))."
            case .unknownTool(let tool):
                return "Unknown MCP tool: \(tool)"
            case .invalidToolArgs:
                return "Invalid tool arguments."
            }
        }
    }
}
