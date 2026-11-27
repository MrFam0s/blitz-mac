import Foundation

struct SequencedPipeBuffer {
    private let newline: UInt8 = 0x0A
    private var buffer = Data()
    private var pendingChunks: [Int: Data] = [:]
    private var nextSequence = 0

    mutating func append(_ data: Data, sequence: Int) -> [Data] {
        pendingChunks[sequence] = data

        var lines: [Data] = []
        while let nextChunk = pendingChunks.removeValue(forKey: nextSequence) {
            nextSequence += 1

            if nextChunk.isEmpty {
                if !buffer.isEmpty {
                    lines.append(buffer)
                    buffer.removeAll(keepingCapacity: false)
                }
                continue
            }

            buffer.append(nextChunk)

            while let newlineIndex = buffer.firstIndex(of: newline) {
                let line = buffer.prefix(upTo: newlineIndex).filter { $0 != 0x0D }
                buffer.removeSubrange(...newlineIndex)
                lines.append(Data(line))
            }
        }

        return lines
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        pendingChunks.removeAll()
        nextSequence = 0
    }
}

actor ASCDaemonClient {
    private final class SequenceCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let current = value
            value += 1
            return current
        }
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Swift.Error>
        let summary: String
        let startedAt: Date
    }

    struct HTTPResponse: Sendable {
        let statusCode: Int
        let headers: [String: [String]]
        let contentType: String
        let body: Data
    }

    private struct DaemonResponse<Result: Decodable>: Decodable {
        let id: String?
        let result: Result?
        let error: DaemonErrorPayload?
    }

    private struct DaemonErrorPayload: Decodable {
        let code: Int
        let message: String
        let data: String?
    }

    private struct SessionOpenResult: Decodable {
        let session: SessionInfo
    }

    private struct SessionInfo: Decodable {
        let profile: String?
        let usesInMemoryKey: Bool
    }

    private struct SessionRequestResult: Decodable {
        let statusCode: Int
        let headers: [String: [String]]?
        let contentType: String?
        let body: String?
    }

    enum Error: LocalizedError {
        case helperNotFound(String)
        case helperLaunchFailed(String)
        case invalidResponse
        case processExited(Int32, String)
        case helperError(String, String?)
        case invalidRequestBody
        case responseTimeout(String)

        var errorDescription: String? {
            switch self {
            case .helperNotFound(let message),
                 .helperLaunchFailed(let message):
                return message
            case .invalidResponse:
                return "Invalid response from ascd"
            case .processExited(let code, let stderr):
                if stderr.isEmpty {
                    return "ascd exited with status \(code)"
                }
                return "ascd exited with status \(code): \(stderr)"
            case .helperError(let message, let data):
                if let data, !data.isEmpty {
                    return "\(message): \(data)"
                }
                return message
            case .invalidRequestBody:
                return "Request body must be valid JSON"
            case .responseTimeout(let summary):
                return "Timed out waiting for ascd response: \(summary)"
            }
        }
    }

    private let credentials: ASCCredentials
    private let executableURL: URL?
    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()
    private let logger = ASCDaemonLogger.shared
    private let defaultResponseTimeoutSeconds: TimeInterval = 45

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutReadHandle: FileHandle?
    private var stderrReadHandle: FileHandle?
    private var stdoutBuffer = SequencedPipeBuffer()
    private var stderrBuffer = SequencedPipeBuffer()
    private var pendingResponses: [String: PendingRequest] = [:]
    private var recentStderr: [String] = []
    private var requestCounter = 0
    private var sessionOpen = false

    init(credentials: ASCCredentials, executableURL: URL? = nil) {
        self.credentials = credentials
        self.executableURL = executableURL
        Task {
            await logger.info("ASCDaemonClient initialized keyId=\(Self.redact(credentials.keyId)) issuerId=\(Self.redact(credentials.issuerId))")
        }
    }

    deinit {
        stdoutReadHandle?.readabilityHandler = nil
        stderrReadHandle?.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }

    func request(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutMs: Int = 30_000,
        expectedStatusCodes: Set<Int> = []
    ) async throws -> HTTPResponse {
        let child = try await ensureSessionOpen()

        var params: [String: Any] = [
            "method": method,
            "path": path,
        ]
        if !headers.isEmpty {
            params["headers"] = headers
        }
        if timeoutMs > 0 {
            params["timeoutMs"] = timeoutMs
        }
        if let body {
            params["body"] = try jsonObject(from: body)
        }

        let result: SessionRequestResult = try await send(method: "session.request", params: params, on: child)
        let response = HTTPResponse(
            statusCode: result.statusCode,
            headers: result.headers ?? [:],
            contentType: result.contentType ?? "",
            body: Data((result.body ?? "").utf8)
        )
        if (200..<300).contains(response.statusCode) || expectedStatusCodes.contains(response.statusCode) {
            await logger.debug("session.request \(method.uppercased()) \(Self.truncate(path)) -> \(response.statusCode) bytes=\(response.body.count)")
        } else {
            let bodySnippet = Self.truncate(String(decoding: ASCTestFlightPrivacy.bodyForLogging(response.body, path: path), as: UTF8.self), limit: 1200)
            await logger.error("session.request \(method.uppercased()) \(Self.truncate(path)) -> \(response.statusCode) contentType=\(response.contentType) body=\(bodySnippet)")
        }
        return response
    }

    func cliExec(
        args: [String],
        responseTimeoutSeconds: TimeInterval? = nil
    ) async throws -> (exitCode: Int, stdout: String, stderr: String) {
        struct CLIExecResult: Decodable {
            let exitCode: Int
            let stdout: String?
            let stderr: String?
        }

        let result: CLIExecResult = try await send(
            method: "cli.exec",
            params: ["args": args],
            on: ensureProcessRunning(),
            responseTimeoutSeconds: responseTimeoutSeconds
        )
        return (result.exitCode, result.stdout ?? "", result.stderr ?? "")
    }

    func chinaForms(writing: Bool, params: [String: Any]) async throws -> Data {
        let result: [String: AnyCodable] = try await send(
            method: writing ? "store.chinaForms.set" : "store.chinaForms.get", params: params,
            on: ensureProcessRunning(), responseTimeoutSeconds: 255)
        return try JSONEncoder().encode(result)
    }

    /// Fixed read-only operation using the selected API key and one web client
    /// whose app/provider membership is verified before any deep checks.
    func releaseReadiness(appID: String, bundleID: String, versionID: String, platform: String) async throws -> ReleaseReadinessPayload {
        struct Result: Decodable {
            let report: [String: AnyCodable]
            let web: ReleaseWebEvidence
            let exitCode: Int
        }
        let result: Result = try await send(method: "release.readiness", params: [
            "appId": appID, "bundleId": bundleID, "versionId": versionID, "platform": platform
        ], on: ensureProcessRunning(), responseTimeoutSeconds: 240)
        return ReleaseReadinessPayload(report: try JSONEncoder().encode(result.report), web: result.web, exitCode: result.exitCode)
    }

    private func ensureSessionOpen() async throws -> Process {
        let child = try ensureProcessRunning()
        guard !sessionOpen else { return child }
        _ = try await send(method: "session.open", params: nil, on: child) as SessionOpenResult
        guard process === child else { throw Error.helperLaunchFailed("ascd connection closed") }
        sessionOpen = true
        await logger.info("ascd session opened")
        return child
    }

    private func ensureProcessRunning() throws -> Process {
        if let process {
            if process.isRunning { return process }
            discardProcess(error: Error.processExited(process.terminationStatus, recentStderr.joined(separator: "\n")))
        }
        return try startProcess()
    }

    private func startProcess() throws -> Process {
        let executablePath = try executableURL?.path ?? resolveExecutablePath()
        let stdinPipe = try makeSubprocessInputPipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executablePath]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = helperEnvironment()
        process.terminationHandler = { [weak self] exited in
            Task { await self?.handleProcessExit(exited) }
        }

        do {
            try process.run()
        } catch {
            Task {
                await logger.error("Failed to launch ascd at \(executablePath): \(error.localizedDescription)")
            }
            throw Error.helperLaunchFailed("Failed to launch ascd at \(executablePath): \(error.localizedDescription)")
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutReadHandle = stdoutPipe.fileHandleForReading
        self.stderrReadHandle = stderrPipe.fileHandleForReading
        self.sessionOpen = false
        self.recentStderr = []
        self.stdoutBuffer.reset()
        self.stderrBuffer.reset()

        Task {
            await logger.info("Started ascd pid=\(process.processIdentifier) path=\(executablePath)")
        }

        let stdoutSequenceCounter = SequenceCounter()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            guard let process else { return }
            let data = handle.availableData
            let sequence = stdoutSequenceCounter.next()
            Task {
                await self?.handlePipeData(data, isStdout: true, sequence: sequence, from: process)
            }
        }

        let stderrSequenceCounter = SequenceCounter()
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            guard let process else { return }
            let data = handle.availableData
            let sequence = stderrSequenceCounter.next()
            Task {
                await self?.handlePipeData(data, isStdout: false, sequence: sequence, from: process)
            }
        }
        return process
    }

    private func resolveExecutablePath() throws -> String {
        let candidates = helperExecutableCandidates()

        for candidate in candidates where !candidate.isEmpty {
            if fileManager.isExecutableFile(atPath: candidate) {
                Task {
                    await logger.debug("Resolved ascd executable path: \(candidate)")
                }
                return candidate
            }
        }

        let searched = candidates.isEmpty ? "(no candidates)" : candidates.joined(separator: ", ")
        Task {
            await logger.error("ascd executable not found. searched=\(searched)")
        }
        throw Error.helperNotFound(
            "ascd not found. Bundle the signed helper at Contents/Helpers/ascd or set BLITZ_ASCD_PATH to the forked helper binary. Searched: \(searched)"
        )
    }

    private func helperExecutableCandidates() -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func appendCandidate(_ rawValue: String?) {
            guard let rawValue else { return }
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let expanded = NSString(string: trimmed).expandingTildeInPath
            let normalized: String
            if expanded.hasPrefix("/") {
                normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            } else {
                normalized = expanded
            }

            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            candidates.append(normalized)
        }

        appendCandidate(ProcessInfo.processInfo.environment["BLITZ_ASCD_PATH"])
        appendCandidate(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ascd").path)
        appendCandidate(
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers/ascd").path
        )
        appendCandidate(Bundle.main.privateFrameworksURL?.deletingLastPathComponent().appendingPathComponent("Helpers/ascd").path)

        return candidates
    }

    /// The app's daemon and its CLI subprocesses must use the selected ASC key.
    /// Inherited token providers or web brokers must not override that account or session.
    nonisolated static func credentialEnvironment(
        credentials: ASCCredentials,
        inherited: [String: String]
    ) -> [String: String] {
        var environment = inherited
        environment["ASC_KEY_ID"] = credentials.keyId
        environment["ASC_ISSUER_ID"] = credentials.issuerId
        environment["ASC_PRIVATE_KEY"] = credentials.privateKey
        environment["ASC_PRIVATE_KEY_PATH"] = nil
        environment["ASC_PRIVATE_KEY_B64"] = nil
        environment["ASC_BEARER_TOKEN"] = nil
        environment["ASC_BEARER_TOKEN_COMMAND"] = nil
        environment["ASC_WEB_BROKER_URL"] = nil
        environment["ASC_WEB_BROKER_TOKEN"] = nil
        environment["ASC_KEY_TYPE"] = nil
        environment["ASC_BYPASS_KEYCHAIN"] = "1"
        return environment
    }

    private func helperEnvironment() -> [String: String] {
        var environment = Self.credentialEnvironment(
            credentials: credentials,
            inherited: ProcessInfo.processInfo.environment
        )
        if environment["ASC_DEBUG"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            environment["ASC_DEBUG"] = nil
        }

        let isolatedConfigPath = fileManager.temporaryDirectory
            .appendingPathComponent("blitz-ascd-\(UUID().uuidString).json")
        try? fileManager.removeItem(at: isolatedConfigPath)
        environment["ASC_CONFIG_PATH"] = isolatedConfigPath.path
        Task {
            await logger.debug(
                "Prepared ascd environment keyId=\(Self.redact(credentials.keyId)) " +
                "issuerId=\(Self.redact(credentials.issuerId)) " +
                "configPath=\(isolatedConfigPath.path) " +
                "ascDebug=\(environment["ASC_DEBUG"] ?? "")"
            )
        }
        return environment
    }

    private func handlePipeData(_ data: Data, isStdout: Bool, sequence: Int, from child: Process) async {
        guard process === child else { return }
        let lineData = if isStdout {
            stdoutBuffer.append(data, sequence: sequence)
        } else {
            stderrBuffer.append(data, sequence: sequence)
        }

        for entry in lineData {
            guard process === child else { return }
            if let line = String(data: entry, encoding: .utf8) {
                if isStdout {
                    await handleStdoutLine(line)
                } else {
                    await handleStderrLine(line)
                }
            } else {
                await logger.error("Received non-UTF8 pipe output: \(entry.count) bytes")
            }
        }
    }

    private func handleStdoutLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else {
            await logger.error("Received non-UTF8 stdout from ascd")
            return
        }

        let metadata = Self.responseMetadata(from: data)
        guard let id = metadata.id else {
            await logger.error("Received stdout line without response id: bytes=\(data.count)")
            return
        }

        guard let pending = pendingResponses.removeValue(forKey: id) else {
            await logger.error("Received unmatched response id=\(id) summary=\(metadata.summary) bytes=\(data.count)")
            return
        }

        let elapsed = Date().timeIntervalSince(pending.startedAt)
        await logger.debug("<- [\(id)] \(pending.summary) response=\(metadata.summary) elapsed=\(String(format: "%.3f", elapsed))s")
        pending.continuation.resume(returning: data)
    }

    private func handleStderrLine(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentStderr.append(trimmed)
        if recentStderr.count > 30 {
            recentStderr.removeFirst(recentStderr.count - 30)
        }
        await logger.error("ascd stderr: \(trimmed)")
    }

    private func handleProcessExit(_ exited: Process) async {
        guard process === exited else { return }
        let message = recentStderr.joined(separator: "\n")
        let status = exited.terminationStatus
        discardProcess(error: Error.processExited(status, message))
        await logger.error("ascd exited status=\(status) stderr=\(Self.truncate(message, limit: 1200))")
    }

    private func discardProcess(error: Swift.Error) {
        for (_, pending) in pendingResponses {
            pending.continuation.resume(throwing: error)
        }
        pendingResponses.removeAll()

        if process?.isRunning == true { process?.terminate() }
        process = nil
        stdinHandle = nil
        sessionOpen = false
        stdoutReadHandle?.readabilityHandler = nil
        stderrReadHandle?.readabilityHandler = nil
        stdoutReadHandle = nil
        stderrReadHandle = nil
        stdoutBuffer.reset()
        stderrBuffer.reset()
    }

    private func send<Result: Decodable>(
        method: String,
        params: [String: Any]?,
        on child: Process,
        responseTimeoutSeconds: TimeInterval? = nil,
        as type: Result.Type = Result.self
    ) async throws -> Result {
        guard process === child, let writer = stdinHandle else {
            throw Error.helperLaunchFailed("ascd connection closed")
        }

        requestCounter += 1
        let id = "ascd-\(requestCounter)"
        let summary = Self.requestSummary(method: method, params: params)

        var request: [String: Any] = [
            "id": id,
            "method": method,
        ]
        if let params {
            request["params"] = params
        }

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        await logger.debug("-> [\(id)] \(summary)")

        let timeoutSeconds = responseTimeoutSeconds ?? defaultResponseTimeoutSeconds
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                await self?.failPendingRequest(id: id, error: Error.responseTimeout(summary))
            } catch {}
        }

        defer { timeoutTask.cancel() }
        let rawResponse = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Swift.Error>) in
            guard writer === stdinHandle else {
                continuation.resume(throwing: Error.helperLaunchFailed("ascd connection closed"))
                return
            }
            pendingResponses[id] = PendingRequest(
                continuation: continuation,
                summary: summary,
                startedAt: Date()
            )
            do {
                var line = requestData
                line.append(0x0A)
                try writer.write(contentsOf: line)
            } catch {
                // A partial write can have reached the helper. Fail its requests without replaying them.
                discardProcess(error: error)
            }
        }

        let response: DaemonResponse<Result>
        do {
            response = try decoder.decode(DaemonResponse<Result>.self, from: rawResponse)
        } catch {
            await logger.error("Failed to decode response for [\(id)] \(summary): type=\(Swift.type(of: error)) bytes=\(rawResponse.count)")
            throw error
        }
        if let error = response.error {
            let privateResponse = ASCTestFlightPrivacy.shouldRedact(path: params?["path"] as? String ?? "")
            let detail = privateResponse ? "<private TestFlight error omitted>" : "message=\(error.message) data=\(error.data ?? "")"
            await logger.error("Helper returned error for [\(id)] \(summary): code=\(error.code) \(detail)")
            throw Error.helperError(error.message, error.data)
        }
        guard let result = response.result else {
            await logger.error("Missing result payload for [\(id)] \(summary)")
            throw Error.invalidResponse
        }
        return result
    }

    private func failPendingRequest(id: String, error: Swift.Error) async {
        guard let pending = pendingResponses.removeValue(forKey: id) else { return }
        pending.continuation.resume(throwing: error)
        discardProcess(error: Error.helperLaunchFailed("ascd connection closed after another request timed out"))
        await logger.error("Timed out waiting for [\(id)] \(pending.summary)")
    }

    nonisolated static func responseMetadata(from data: Data) -> (id: String?, summary: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, "invalid-json")
        }

        let id = json["id"] as? String

        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? 0
            return (id, "error code=\(code)")
        }

        if let result = json["result"] as? [String: Any] {
            if let statusCode = result["statusCode"] as? Int {
                let contentType = result["contentType"] as? String ?? ""
                return (id, "statusCode=\(statusCode) contentType=\(Self.truncate(contentType, limit: 120))")
            }
            let keys = result.keys.sorted().joined(separator: ",")
            return (id, "result keys=\(keys)")
        }

        return (id, "unknown-payload")
    }

    private func jsonObject(from data: Data) throws -> Any {
        guard !data.isEmpty else { return NSNull() }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func requestSummary(method: String, params: [String: Any]?) -> String {
        switch method {
        case "session.open":
            let profile = (params?["profile"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return profile.isEmpty ? "session.open" : "session.open profile=\(profile)"
        case "session.request":
            let httpMethod = (params?["method"] as? String)?.uppercased() ?? "UNKNOWN"
            let path = truncate(params?["path"] as? String ?? "")
            let timeoutDescription: String
            if let timeoutMs = params?["timeoutMs"] as? Int, timeoutMs > 0 {
                timeoutDescription = " timeoutMs=\(timeoutMs)"
            } else {
                timeoutDescription = ""
            }
            let bodyDescription: String
            if let body = params?["body"] {
                if let data = try? JSONSerialization.data(withJSONObject: body) {
                    bodyDescription = " bodyBytes=\(data.count)"
                } else {
                    bodyDescription = " body=unserializable"
                }
            } else {
                bodyDescription = ""
            }
            return "session.request \(httpMethod) \(path)\(timeoutDescription)\(bodyDescription)"
        case "cli.exec":
            let args = params?["args"] as? [String] ?? []
            return "cli.exec args=\(truncate(args.joined(separator: " "), limit: 200))"
        default:
            return params == nil ? method : "\(method) params"
        }
    }

    private static func truncate(_ value: String, limit: Int = 300) -> String {
        let normalized = value.replacingOccurrences(of: "\n", with: "\\n")
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }

    private static func redact(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else {
            return String(repeating: "*", count: max(trimmed.count, 1))
        }
        let prefix = trimmed.prefix(4)
        let suffix = trimmed.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}
