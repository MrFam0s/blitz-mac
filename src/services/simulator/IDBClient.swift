import Foundation

/// Protocol for interacting with idb (iOS Development Bridge)
/// Uses a persistent `idb shell` process for low-latency command execution
actor IDBClient {
    private var shellProcess: Process?
    private var stdinPipe: Pipe?
    private var udid: String?
    private var companionProcess: Process?
    private var socketDirectory: URL?
    private var connectionInUse = false
    private var closed = false
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// IDB companions can log their launch environment. Never pass app credentials,
    /// agent API keys, Python injection settings or arbitrary IDB_* variables.
    nonisolated static func helperEnvironment(_ source: [String: String]) -> [String: String] {
        let allowed: Set<String> = ["HOME", "PATH", "TMPDIR", "USER", "LOGNAME",
                                    "LANG", "LC_ALL", "LC_CTYPE", "DEVELOPER_DIR"]
        return source.filter { allowed.contains($0.key) }
    }

    /// Resolve the idb binary path — prefer ~/.blitz/python/bin/idb
    private static func resolveIdbPath() -> String {
        if FileManager.default.fileExists(atPath: BlitzPaths.idbPath.path) {
            return BlitzPaths.idbPath.path
        }
        for path in ["/opt/homebrew/bin/idb", "/usr/local/bin/idb"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/opt/homebrew/bin/idb"
    }

    /// Resolve idb_companion path
    private static func resolveCompanionPath() -> String? {
        if FileManager.default.fileExists(atPath: BlitzPaths.idbCompanionPath.path) {
            return BlitzPaths.idbCompanionPath.path
        }
        // Check homebrew
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/idb_companion") {
            return "/opt/homebrew/bin/idb_companion"
        }
        return nil
    }

    private static let idbPath = resolveIdbPath()
    private static let companionPath = resolveCompanionPath()

    nonisolated static func companionArguments(udid: String, socket: String) -> [String] {
        ["--udid", udid, "--only", "simulator", "--grpc-domain-sock", socket]
    }

    // Actor methods may interleave across startup awaits. Serialize connection
    // setup and writes so rapid first taps cannot launch competing helpers.
    private func acquireConnection() async {
        if connectionInUse {
            await withCheckedContinuation { connectionWaiters.append($0) }
        } else {
            connectionInUse = true
        }
    }

    private func releaseConnection() {
        if connectionWaiters.isEmpty { connectionInUse = false }
        else { connectionWaiters.removeFirst().resume() }
    }

    /// Ensure we have a running shell process for the given UDID
    private func ensureShell(udid: String) async throws {
        guard !closed else { throw CancellationError() }
        if self.udid == udid, shellProcess?.isRunning == true, companionProcess?.isRunning == true {
            return
        }

        stopProcesses()
        guard UUID(uuidString: udid) != nil, let companionPath = Self.companionPath else {
            throw IDBError.shellNotAvailable
        }
        // A private socket avoids stale global IDB registrations and discovery
        // of physical devices when this view only needs one known simulator.
        // /tmp keeps the UNIX socket path below macOS's length limit.
        let directory = URL(fileURLWithPath: "/tmp/blitz-idb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        socketDirectory = directory
        let socket = directory.appendingPathComponent("companion.sock").path
        let companion = Process()
        companion.executableURL = URL(fileURLWithPath: companionPath)
        companion.arguments = Self.companionArguments(udid: udid, socket: socket)
        if companionPath == BlitzPaths.idbCompanionPath.path,
           (try? String(contentsOf: BlitzPaths.root.appendingPathComponent("idb-companion/.blitz-version")))?.hasPrefix("1.7.6 ") == true {
            companion.arguments! += ["--idle-shutdown-time", "60"]
        }
        companion.environment = Self.helperEnvironment(ProcessInfo.processInfo.environment)
        companion.standardOutput = FileHandle.nullDevice
        companion.standardError = FileHandle.nullDevice
        companionProcess = companion
        do {
            try companion.run()
            for _ in 0..<50 {
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                guard companion.isRunning else { throw IDBError.shellNotAvailable }
                if FileManager.default.fileExists(atPath: socket) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard FileManager.default.fileExists(atPath: socket) else { throw IDBError.shellNotAvailable }
        } catch {
            stopProcesses()
            throw error
        }
        let args = ["--companion", socket, "shell", "--no-prompt", "--udid", udid]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.idbPath)
        process.arguments = args
        process.environment = Self.helperEnvironment(ProcessInfo.processInfo.environment)

        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        self.shellProcess = process
        self.stdinPipe = stdin
        self.udid = udid
        do {
            try process.run()
            try await Task.sleep(for: .milliseconds(500))
            guard !closed else { throw CancellationError() }
            guard process.isRunning else { throw IDBError.shellNotAvailable }
        } catch {
            stopProcesses()
            throw error
        }
    }

    /// Send a command through the shell's stdin
    private func runInShell(udid: String, command: String) async throws {
        await acquireConnection()
        defer { releaseConnection() }
        try Task.checkCancellation()
        try await ensureShell(udid: udid)

        guard let stdin = stdinPipe else {
            throw IDBError.shellNotAvailable
        }

        let data = (command + "\n").data(using: .utf8)!
        stdin.fileHandleForWriting.write(data)
    }

    /// Run a direct idb command (not through shell) and return output
    private func runDirect(udid: String, _ arguments: [String]) async throws -> String {
        await acquireConnection()
        let socket: String
        do {
            try Task.checkCancellation()
            try await ensureShell(udid: udid)
            guard let socketDirectory else { throw IDBError.shellNotAvailable }
            socket = socketDirectory.appendingPathComponent("companion.sock").path
        } catch {
            releaseConnection()
            throw error
        }
        releaseConnection()
        // Do not hold the startup gate across a potentially long CLI query.
        var args = ["--companion", socket]
        args.append(contentsOf: arguments)
        return try await ProcessRunner.run(Self.idbPath, arguments: args,
            environment: Self.helperEnvironment(ProcessInfo.processInfo.environment),
            inheritEnvironment: false)
    }

    // MARK: - Device Actions (via persistent shell for speed)

    /// Tap at coordinates
    func tap(udid: String, x: Double, y: Double, duration: Double? = nil) async throws {
        var cmd = "ui tap \(Int(x)) \(Int(y))"
        if let duration {
            cmd += " --duration \(duration)"
        }
        cmd += " --json"
        try await runInShell(udid: udid, command: cmd)
    }

    /// Swipe between points
    func swipe(udid: String, fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double? = nil, delta: Int? = nil) async throws {
        var cmd = "ui swipe \(Int(fromX)) \(Int(fromY)) \(Int(toX)) \(Int(toY))"
        if let duration {
            cmd += " --duration \(duration)"
        }
        if let delta {
            cmd += " --delta \(delta)"
        }
        cmd += " --json"
        try await runInShell(udid: udid, command: cmd)
    }

    /// Input text
    func inputText(udid: String, text: String) async throws {
        // Manually JSON-encode the string — JSONSerialization rejects bare strings
        // without .fragmentsAllowed, which isn't available on all targets.
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        try await runInShell(udid: udid, command: "ui text \"\(escaped)\" --json")
    }

    /// Press a button (HOME, LOCK, etc.)
    func pressButton(udid: String, button: String) async throws {
        try await runInShell(udid: udid, command: "ui button \(button) --json")
    }

    /// Press a key by HID keycode
    func pressKey(udid: String, keycode: Int, duration: Double? = nil) async throws {
        var cmd = "ui key \(keycode)"
        if let duration {
            cmd += " --duration \(duration)"
        }
        cmd += " --json"
        try await runInShell(udid: udid, command: cmd)
    }

    /// Press a sequence of keys
    func pressKeySequence(udid: String, keys: [Int]) async throws {
        let keyStr = keys.map { String($0) }.joined(separator: " ")
        try await runInShell(udid: udid, command: "ui key-sequence \(keyStr) --json")
    }

    // MARK: - Direct commands (less latency-sensitive)

    /// Describe the full UI hierarchy
    func describeAll(udid: String) async throws -> String {
        try await runDirect(udid: udid, ["ui", "describe-all", "--udid", udid])
    }

    /// Describe the element at a specific point
    func describePoint(udid: String, x: Int, y: Int) async throws -> String {
        try await runDirect(udid: udid, ["ui", "describe-point", "\(x)", "\(y)", "--udid", udid])
    }

    /// Take a screenshot
    func screenshot(udid: String, path: String) async throws {
        _ = try await runDirect(udid: udid, ["screenshot", "--udid", udid, path])
    }

    /// Shutdown the shell when done
    func shutdown() async {
        // Reject both queued and later-scheduled events from the vanished view.
        closed = true
        stopProcesses()
    }

    private func stopProcesses() {
        if shellProcess?.isRunning == true { shellProcess?.terminate() }
        if companionProcess?.isRunning == true { companionProcess?.terminate() }
        shellProcess = nil
        companionProcess = nil
        stdinPipe = nil
        udid = nil
        if let socketDirectory { try? FileManager.default.removeItem(at: socketDirectory) }
        socketDirectory = nil
    }

    enum IDBError: Error, LocalizedError {
        case shellNotAvailable

        var errorDescription: String? {
            switch self {
            case .shellNotAvailable: return "IDB shell process is not available"
            }
        }
    }
}
