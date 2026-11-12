// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// Evidence from the helper's isolated, fresh checks. Cookie presence alone is
/// never a capability proof, and normal ASC login need not prove Portal access.
struct ASCWebSessionImportEvidence: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case verified, unverified, invalid }
    struct Capability: Codable, Equatable, Sendable {
        let status: Status
        let reason: String
    }
    let outcome: String
    let reason: String
    let appleId: String
    let providerId: String
    var developerTeamId: String? = nil
    let asc: Capability
    let developerPortal: Capability

    var acceptsASC: Bool {
        ["imported", "existingPreserved"].contains(outcome) && asc.status == .verified
            && !appleId.isEmpty && !providerId.isEmpty
    }

    func satisfies(requireDeveloperPortal: Bool) -> Bool {
        acceptsASC && (!requireDeveloperPortal || (developerPortal.status == .verified
            && !(developerTeamId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)))
    }
}

/// Uses the helper's validated, atomic session selection. Existing stronger CLI
/// sessions remain intact; no cache is overwritten by a blind portable import.
struct ASCWebSessionCLIImporter {
    enum ImportError: Error, LocalizedError {
        case helperUnavailable, invalidSession, rejected, timedOut, identityChanged

        var errorDescription: String? {
            switch self {
            case .helperUnavailable: return "Der ASC-Helfer ist nicht verfügbar. Bitte Blitz Neo neu starten."
            case .invalidSession: return "Apple hat noch keine eindeutige App-Store-Connect-Anmeldung mit Anbieter bestätigt."
            case .rejected: return "ASC konnte die Apple-Anmeldung nicht bestätigen oder speichern. Bitte die Anmeldung abschließen und erneut prüfen."
            case .timedOut: return "Die Prüfung der Apple-Anmeldung hat zu lange gedauert. Bitte erneut versuchen."
            case .identityChanged: return "Apple-Konto oder Anbieter haben sich während der Sitzungsprüfung geändert. Bitte die Anmeldung erneut prüfen."
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

    @discardableResult
    func importSession(_ session: IrisSession) async throws -> ASCWebSessionImportEvidence {
        try Task.checkCancellation()
        guard let helperPath else { throw ImportError.helperUnavailable }
        let bundle = try Self.bundleData(for: session)
        guard let providerID = session.publicProviderId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty else { throw ImportError.invalidSession }
        let requestID = UUID().uuidString
        let request = try JSONSerialization.data(withJSONObject: ["id": requestID, "method": "web.session.import",
            "params": ["bundle": try JSONSerialization.jsonObject(with: bundle), "expectedProviderId": providerID]]) + Data([0x0a])
        let directory = temporaryDirectory.appendingPathComponent("blitz-web-auth-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("request.json")
        guard fileManager.createFile(atPath: file.path, contents: request, attributes: [.posixPermissions: 0o600]) else {
            throw ImportError.rejected
        }
        var env = environment
        if env["ASC_BYPASS_KEYCHAIN", default: ""].isEmpty { env["ASC_BYPASS_KEYCHAIN"] = "1" }
        env["ASC_TELEMETRY_DISABLED"] = "1"
        let (exitCode, output) = try await runner(helperPath, [], env, directory)
        try Task.checkCancellation()
        guard exitCode == 0,
              let response = try? JSONDecoder().decode(Response.self, from: output), response.id == requestID,
              let receipt = response.result, receipt.acceptsASC else { throw ImportError.rejected }
        guard receipt.appleId.caseInsensitiveCompare(session.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == .orderedSame,
              receipt.providerId == providerID else { throw ImportError.identityChanged }
        return receipt
    }

    private struct Response: Decodable {
        let id: String?
        let result: ASCWebSessionImportEvidence?
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
        let input = try FileHandle(forReadingFrom: directory.appendingPathComponent("request.json"))
        defer { try? input.close() }
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { lock.unlock(); throw ASCWebSessionCLIImporter.ImportError.helperUnavailable }
        lock.unlock()
        let deadline = Date().addingTimeInterval(90)
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
        let receiptFile = try FileHandle(forReadingFrom: outputURL)
        defer { try? receiptFile.close() }
        return (child.terminationStatus, try receiptFile.read(upToCount: 65_536) ?? Data())
    }
}
