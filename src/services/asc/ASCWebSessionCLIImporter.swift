import Foundation

/// Uses ASC's supported, locked import path. The older aggregate export alone
/// is not the file cache that `asc web` reads when Keychain access is bypassed.
struct ASCWebSessionCLIImporter {
    enum ImportError: Error, LocalizedError {
        case helperUnavailable, invalidSession, rejected, timedOut

        var errorDescription: String? {
            switch self {
            case .helperUnavailable: return "Der ASC-Helfer ist nicht verfügbar. Bitte Blitz neu starten."
            case .invalidSession: return "Apple hat noch keine vollständige Anmeldung bestätigt."
            case .rejected: return "ASC konnte die Apple-Anmeldung nicht bestätigen oder speichern. Bitte die Anmeldung abschließen und erneut prüfen."
            case .timedOut: return "Die Prüfung der Apple-Anmeldung hat zu lange gedauert. Bitte erneut versuchen."
            }
        }
    }

    typealias Runner = @Sendable (String, [String], [String: String], URL) async throws -> (Int32, Data)
    var helperPath: String? = ASCAuthBridge.resolveBundledASCDPath(
        fileManager: .default, environment: ProcessInfo.processInfo.environment
    )
    var environment = ProcessInfo.processInfo.environment
    var temporaryDirectory = FileManager.default.temporaryDirectory
    var runner: Runner = { path, arguments, environment, directory in
        let execution = ImportProcess()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached {
                try execution.run(path: path, arguments: arguments, environment: environment, directory: directory)
            }.value
        } onCancel: {
            execution.cancel()
        }
    }

    func importSession(_ session: IrisSession) async throws {
        try Task.checkCancellation()
        guard let helperPath else { throw ImportError.helperUnavailable }
        let bundle = try Self.bundleData(for: session)
        let directory = temporaryDirectory.appendingPathComponent("blitz-web-auth-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        guard fileManager.createFile(atPath: file.path, contents: bundle, attributes: [.posixPermissions: 0o600]) else {
            throw ImportError.rejected
        }
        var env = environment
        if env["ASC_BYPASS_KEYCHAIN", default: ""].isEmpty { env["ASC_BYPASS_KEYCHAIN"] = "1" }
        env["ASC_TELEMETRY_DISABLED"] = "1"
        let arguments = ["__ascd_run_cli__", "web", "auth", "import", "--file", file.path,
                         "--validate", "--overwrite", "--output", "json"]
        let (exitCode, output) = try await runner(helperPath, arguments, env, directory)
        try Task.checkCancellation()
        guard exitCode == 0,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: output), receipt.imported,
              receipt.cookieCount > 0,
              receipt.appleId.caseInsensitiveCompare(session.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == .orderedSame else {
            throw ImportError.rejected
        }
    }

    private struct Receipt: Decodable {
        let imported: Bool
        let appleId: String
        let cookieCount: Int
    }

    static func bundleData(for session: IrisSession) throws -> Data {
        guard let email = session.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            throw ImportError.invalidSession
        }
        let data = try ASCWebSessionStore.mergedData(storing: session, into: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let store = try decoder.decode(ASCWebSessionStore.self, from: data)
        guard let key = store.lastKey, let saved = store.sessions[key] else { throw ImportError.invalidSession }
        let formatter = ISO8601DateFormatter()
        let cookies: [[String: Any]] = saved.cookies.keys.sorted().flatMap { origin in
            var seen = Set<String>()
            // ASC portable bundles accept only host-scoped cookies. A browser
            // .apple.com cookie is already assigned to each permitted origin by
            // the store; narrow its scope and prefer a more specific duplicate.
            let scoped = saved.cookies[origin, default: []].sorted { $0.domain.count > $1.domain.count }
            return scoped.filter { cookie in
                seen.insert(cookie.name + "\n" + cookie.path).inserted
            }.map { cookie in
                var value: [String: Any] = ["url": origin, "name": cookie.name, "value": cookie.value,
                                            "domain": URL(string: origin)!.host!, "path": cookie.path,
                                            "secure": cookie.secure, "httpOnly": cookie.httpOnly]
                if let expires = cookie.expires { value["expires"] = formatter.string(from: expires) }
                if let maxAge = cookie.maxAge { value["maxAge"] = maxAge }
                if let sameSite = cookie.sameSite { value["sameSite"] = sameSite }
                return value
            }
        }
        guard !cookies.isEmpty else { throw ImportError.invalidSession }
        return try JSONSerialization.data(withJSONObject: ["kind": "asc-web-session", "version": 1,
            "exportedAt": formatter.string(from: session.capturedAt), "appleId": email, "cookies": cookies])
    }
}

/// No shell, no raw helper output in logs, and a hard deadline even if a network
/// request stalls. Cancellation stops the helper before the login callback runs.
private final class ImportProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    func run(path: String, arguments: [String], environment: [String: String], directory: URL) throws -> (Int32, Data) {
        let outputURL = directory.appendingPathComponent("receipt.json")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ASCWebSessionCLIImporter.ImportError.rejected
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: path)
        child.arguments = arguments
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { lock.unlock(); throw ASCWebSessionCLIImporter.ImportError.helperUnavailable }
        lock.unlock()
        let deadline = Date().addingTimeInterval(45)
        while child.isRunning {
            lock.lock()
            let stopped = cancelled
            lock.unlock()
            if stopped || Date() >= deadline {
                child.terminate()
                // The helper is our child; ensure it cannot write a cache after cancellation.
                for _ in 0..<20 where child.isRunning { Thread.sleep(forTimeInterval: 0.05) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
                if stopped { throw CancellationError() }
                throw ASCWebSessionCLIImporter.ImportError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        child.waitUntilExit()
        let input = try FileHandle(forReadingFrom: outputURL)
        defer { try? input.close() }
        return (child.terminationStatus, try input.read(upToCount: 65_536) ?? Data())
    }
}
