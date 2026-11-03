import Foundation
import CoreFoundation

/// Identity read from the actual upload payload, never inferred from a filename or UI selection.
struct BuildArtifactMetadata: Equatable, Sendable {
    let bundleID: String
    let shortVersion: String
    let buildNumber: String
    let platform: ProjectPlatform
    let usesNonExemptEncryption: Bool?

    struct ValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func numericComponents(_ value: String) -> [String]? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count), components.allSatisfy({
            !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" }
        }) else { return nil }
        return components.map { component in
            let trimmed = component.drop(while: { $0 == "0" })
            return trimmed.isEmpty ? "0" : String(trimmed)
        }
    }

    /// Compare numeric components without converting arbitrarily large input to Int.
    static func compareNumbers(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard var left = numericComponents(lhs), var right = numericComponents(rhs) else { return nil }
        while left.count < 3 { left.append("0") }
        while right.count < 3 { right.append("0") }
        for (a, b) in zip(left, right) where a != b {
            if a.count != b.count { return a.count < b.count ? .orderedAscending : .orderedDescending }
            return a < b ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    static func fromPlist(_ data: Data, platform: ProjectPlatform) throws -> Self {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ValidationError(message: "The artifact's Info.plist is not a dictionary.")
        }
        func requiredString(_ key: String) throws -> String {
            guard let value = plist[key] as? String, !value.isEmpty,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw ValidationError(message: "The artifact has no valid \(key). Rebuild before uploading.")
            }
            return value
        }
        let bundleID = try requiredString("CFBundleIdentifier")
        let version = try requiredString("CFBundleShortVersionString")
        let build = try requiredString("CFBundleVersion")
        guard numericComponents(version) != nil,
              let buildParts = numericComponents(build), buildParts.first != "0" else {
            throw ValidationError(message: "Version '\(version)' and build '\(build)' must contain one to three numeric components; the build must start with a positive number.")
        }
        let declaredPlatforms = (plist["CFBundleSupportedPlatforms"] as? [String]) ?? []
        let platformName = plist["DTPlatformName"] as? String
        let allowedName = platform == .macOS ? "macosx" : "iphoneos"
        guard !declaredPlatforms.isEmpty || platformName?.isEmpty == false else {
            throw ValidationError(message: "The artifact does not declare its platform (CFBundleSupportedPlatforms or DTPlatformName). Rebuild it with the intended Xcode destination before uploading.")
        }
        if (!declaredPlatforms.isEmpty && declaredPlatforms.map({ $0.lowercased() }) != [allowedName])
            || (platformName != nil && platformName?.lowercased() != allowedName) {
            throw ValidationError(message: "The artifact platform does not match \(platform.rawValue). Simulator builds cannot be uploaded.")
        }
        var encryption: Bool?
        if let value = plist["ITSAppUsesNonExemptEncryption"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw ValidationError(message: "ITSAppUsesNonExemptEncryption must be a Boolean describing the app's actual encryption use.")
            }
            encryption = number.boolValue
        }
        return Self(bundleID: bundleID, shortVersion: version, buildNumber: build,
                    platform: platform, usesNonExemptEncryption: encryption)
    }

    func validate(bundleID expectedBundleID: String, platform expectedPlatform: ProjectPlatform, version: String? = nil) throws {
        guard bundleID == expectedBundleID, platform == expectedPlatform else {
            throw ValidationError(message: "Artifact identity mismatch: \(bundleID) (\(platform.rawValue)); expected \(expectedBundleID) (\(expectedPlatform.rawValue)).")
        }
        if let version, shortVersion != version {
            throw ValidationError(message: "Artifact version \(shortVersion) does not match the selected App Store version \(version). Select the matching version or rebuild; no upload was started.")
        }
    }

    func validateExportMatchesArchive(_ archive: Self) throws {
        guard self == archive else {
            throw ValidationError(message: "Export changed the archived app identity, version, build number or encryption declaration. Archive: \(archive.bundleID) \(archive.shortVersion) (\(archive.buildNumber)); export: \(bundleID) \(shortVersion) (\(buildNumber)). Rebuild before uploading.")
        }
    }

    /// No shell interpolation: paths containing quotes, spaces or shell syntax remain literal arguments.
    private static func commandData(_ executable: String, _ arguments: [String], limit: Int = 8 * 1024 * 1024) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BlitzArtifactCommand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let errorURL = directory.appendingPathComponent("stderr")
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = errorHandle
        try process.run()
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard data.count + chunk.count <= limit else {
                process.terminate()
                process.waitUntilExit()
                throw ValidationError(message: "Artifact metadata exceeds the allowed size.")
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = try Data(contentsOf: errorURL)
            let message = String(decoding: errorData.prefix(8192), as: UTF8.self)
            throw ValidationError(message: "Cannot inspect artifact: \(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus)): \(message)")
        }
        return data
    }

    static func read(artifactURL: URL, platform: ProjectPlatform) async throws -> Self {
        try await Task.detached(priority: .userInitiated) {
            let url = artifactURL.standardizedFileURL
            let expectedExtension = platform == .macOS ? "pkg" : "ipa"
            guard url.pathExtension.lowercased() == expectedExtension,
                  FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError(message: "Provide an existing .\(expectedExtension) for the selected \(platform.rawValue) app.")
            }
            if platform == .iOS {
                let listing = try commandData("/usr/bin/unzip", ["-Z1", url.path])
                let entries = String(decoding: listing, as: UTF8.self).components(separatedBy: .newlines)
                let plistEntries = entries.filter { entry in
                    let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
                    return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
                }
                guard plistEntries.count == 1, let entry = plistEntries.first else {
                    throw ValidationError(message: "The IPA must contain exactly one top-level application's Info.plist.")
                }
                return try fromPlist(commandData("/usr/bin/unzip", ["-p", url.path, entry]), platform: platform)
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlitzArtifactPackage-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let payloadPaths = String(decoding: try commandData("/usr/sbin/pkgutil", ["--payload-files", url.path]), as: UTF8.self)
            guard !payloadPaths.components(separatedBy: .newlines).contains(where: {
                $0.hasPrefix("/") || $0.split(separator: "/").contains("..")
            }) else { throw ValidationError(message: "The package contains unsafe payload paths.") }
            let expanded = root.appendingPathComponent("expanded")
            _ = try commandData("/usr/sbin/pkgutil", ["--expand-full", url.path, expanded.path])
            let apps = try topLevelApps(in: expanded)
            guard apps.count == 1, let app = apps.first else {
                throw ValidationError(message: "The PKG must contain exactly one top-level application; found \(apps.count).")
            }
            return try readApp(app, root: expanded, platform: platform)
        }.value
    }

    private static func topLevelApps(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw ValidationError(message: "Cannot inspect expanded package.")
        }
        var apps: [URL] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "app" {
                apps.append(url)
                enumerator.skipDescendants()
            }
        }
        return apps
    }

    private static func readApp(_ app: URL, root: URL, platform: ProjectPlatform) throws -> Self {
        let info = app.appendingPathComponent(platform == .macOS ? "Contents/Info.plist" : "Info.plist").resolvingSymlinksInPath()
        guard info.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw ValidationError(message: "Application metadata points outside its artifact.")
        }
        let size = try info.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else { throw ValidationError(message: "Artifact metadata exceeds the allowed size.") }
        return try fromPlist(Data(contentsOf: info), platform: platform)
    }

    static func readArchive(at archiveURL: URL, platform: ProjectPlatform) throws -> Self {
        let apps = try FileManager.default.contentsOfDirectory(at: archiveURL.appendingPathComponent("Products/Applications"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else {
            throw ValidationError(message: "The archive must contain exactly one application.")
        }
        return try readApp(app, root: archiveURL, platform: platform)
    }
}


/// Thread-safe collector that keeps enough process output to surface the
/// meaningful failure context instead of only the last stderr lines.
final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let maxStoredLines: Int
    private let maxSummaryLines: Int

    init(maxStoredLines: Int = 400, maxSummaryLines: Int = 60) {
        self.maxStoredLines = maxStoredLines
        self.maxSummaryLines = maxSummaryLines
    }

    func appendStdout(_ chunk: String) {
        append(chunk)
    }

    func appendStderr(_ chunk: String) {
        append(chunk)
    }

    private func append(_ chunk: String) {
        let normalized = chunk.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let splitLines = normalized.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !splitLines.isEmpty else { return }

        lock.lock()
        lines.append(contentsOf: splitLines)
        if lines.count > maxStoredLines {
            lines.removeFirst(lines.count - maxStoredLines)
        }
        lock.unlock()
    }

    var combinedText: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    var summary: String {
        lock.lock()
        let snapshot = lines
        lock.unlock()

        guard !snapshot.isEmpty else { return "" }

        let interestingIndexes = snapshot.indices.filter { Self.isInteresting(snapshot[$0]) }
        if interestingIndexes.isEmpty {
            return Array(snapshot.suffix(maxSummaryLines)).joined(separator: "\n")
        }

        var selectedIndexes: [Int] = []
        for index in interestingIndexes {
            let start = max(snapshot.startIndex, index - 2)
            let end = min(snapshot.index(before: snapshot.endIndex), index + 2)
            selectedIndexes.append(contentsOf: start...end)
        }
        selectedIndexes.append(contentsOf: snapshot.indices.suffix(8))

        var seen: Set<Int> = []
        let filtered = selectedIndexes
            .filter { seen.insert($0).inserted }
            .sorted()
            .suffix(maxSummaryLines)

        return filtered.map { snapshot[$0] }.joined(separator: "\n")
    }

    private static func isInteresting(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return lowercased.contains("error:")
            || lowercased.contains("compileassetcatalogvariant")
            || lowercased.contains("asset catalog")
            || lowercased.contains("appicon")
            || lowercased.contains(".appiconset")
            || lowercased.contains("icon set")
            || lowercased.contains("app store icon")
            || lowercased.contains("actool")
            || lowercased.contains("invalid image")
            || lowercased.contains("missing required icon")
    }

    var lastLogBundlePath: String? {
        let text = combinedText
        guard let range = text.range(of: "Created bundle at path \""),
              let endQuote = text[range.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        return String(text[range.upperBound..<endQuote])
    }

    var allLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// Handles iOS code signing setup, archiving/exporting IPAs, and uploading to TestFlight.
/// Each method is idempotent — re-running skips already-completed steps via cached signing state.
actor BuildPipelineService {
    private static let helperUploadVerifyTimeout = "15s"
    private static let helperUploadWaitResponseTimeoutSeconds: TimeInterval = 15 * 60

    // MARK: - Signing State (persisted for idempotency)

    struct SigningState: Codable {
        var bundleIdResourceId: String?
        var certificateId: String?
        var installerCertificateId: String?
        var profileUUID: String?
        var profileName: String?
        var teamId: String?
    }

    private let fm = FileManager.default

    private func signingStateURL(bundleId: String) -> URL {
        return BlitzPaths.signing(bundleId: bundleId).appendingPathComponent("signing-state.json")
    }

    private func loadSigningState(bundleId: String) -> SigningState {
        let url = signingStateURL(bundleId: bundleId)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SigningState.self, from: data) else {
            return SigningState()
        }
        return state
    }

    private func saveSigningState(_ state: SigningState, bundleId: String) throws {
        let url = signingStateURL(bundleId: bundleId)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Setup Signing

    struct SigningResult {
        let bundleIdResourceId: String
        let certificateId: String
        let installerCertificateId: String?
        let profileUUID: String
        let teamId: String
        let log: [String]
    }

    func setupSigning(
        projectPath: String,
        bundleId: String,
        teamId: String?,
        ascService: AppStoreConnectService,
        platform: ProjectPlatform = .iOS,
        scheme: String? = nil,
        configuration: String? = nil,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> SigningResult {
        // Resolve an unambiguous target before creating certificates or profiles.
        try XcodeProjectIdentityEditor().update(
            projectPath: projectPath, bundleID: bundleId, scheme: scheme,
            configuration: configuration ?? "Release", teamID: teamId ?? "PREFLIGHT", dryRun: true
        )
        var state = loadSigningState(bundleId: bundleId)
        var log: [String] = []

        let isMacOS = platform == .macOS
        let certType = isMacOS ? "MAC_APP_DISTRIBUTION" : "DISTRIBUTION"
        let bundleIdPlatform = isMacOS ? "MAC_OS" : "IOS"
        let profileType = isMacOS ? "MAC_APP_STORE" : "IOS_APP_STORE"

        func emit(_ msg: String) {
            log.append(msg)
            onProgress(msg)
        }

        if isMacOS {
            emit("Setting up macOS App Store signing...")
        }

        // 1. Register bundle ID
        let bundleIdResourceId: String
        if let existing = state.bundleIdResourceId {
            emit("Bundle ID already registered: \(existing)")
            bundleIdResourceId = existing
        } else {
            emit("Checking bundle ID '\(bundleId)'...")
            if let found = try await ascService.fetchBundleId(identifier: bundleId) {
                emit("Bundle ID exists: \(found.id)")
                bundleIdResourceId = found.id
            } else {
                emit("Registering bundle ID (platform: \(bundleIdPlatform))...")
                let appName = bundleId.split(separator: ".").last.map(String.init) ?? bundleId
                let created = try await ascService.registerBundleId(identifier: bundleId, name: appName, platform: bundleIdPlatform)
                emit("Registered bundle ID: \(created.id)")
                bundleIdResourceId = created.id
            }
            state.bundleIdResourceId = bundleIdResourceId
            try saveSigningState(state, bundleId: bundleId)
        }

        // 2. Distribution certificate
        // For macOS: prefer existing universal DISTRIBUTION cert (Apple Distribution) since
        // Xcode uses it by default. Only fall back to MAC_APP_DISTRIBUTION if none found.
        let certificateId: String
        if let existing = state.certificateId {
            emit("\(certType) certificate already configured: \(existing)")
            certificateId = existing
        } else {
            var foundCert: ASCCertificate?

            // For macOS, first check for universal DISTRIBUTION cert (Apple Distribution)
            if isMacOS {
                emit("Checking DISTRIBUTION (Apple Distribution) certificates...")
                let universalCerts = try await ascService.fetchCertificates(type: "DISTRIBUTION")
                foundCert = universalCerts.first
                if let cert = foundCert {
                    emit("Using existing Apple Distribution certificate: \(cert.attributes.displayName ?? cert.id)")
                }
            }

            // Check platform-specific cert type
            if foundCert == nil {
                emit("Checking \(certType) certificates...")
                let certs = try await ascService.fetchCertificates(type: certType)
                foundCert = certs.first
                if let cert = foundCert {
                    emit("Using existing certificate: \(cert.attributes.displayName ?? cert.id)")
                }
            }

            if let cert = foundCert {
                certificateId = cert.id
            } else {
                emit("No distribution certificate found. Creating \(certType)...")
                certificateId = try await createAndImportCertificate(
                    bundleId: bundleId,
                    certType: certType,
                    filePrefix: "dist",
                    csrCN: isMacOS ? "Mac App Distribution" : "Blitz Distribution",
                    ascService: ascService,
                    emit: emit
                )
            }
            state.certificateId = certificateId
            try saveSigningState(state, bundleId: bundleId)
        }

        // 2b. macOS Installer certificate (for signing .pkg)
        if isMacOS {
            if let existing = state.installerCertificateId {
                emit("MAC_INSTALLER_DISTRIBUTION certificate already configured: \(existing)")
            } else {
                emit("Checking MAC_INSTALLER_DISTRIBUTION certificates...")
                let certs = try await ascService.fetchCertificates(type: "MAC_INSTALLER_DISTRIBUTION")
                if let cert = certs.first {
                    emit("Using existing installer certificate: \(cert.attributes.displayName ?? cert.id)")
                    state.installerCertificateId = cert.id
                } else {
                    emit("No MAC_INSTALLER_DISTRIBUTION certificate found. Creating one...")
                    let installerCertId = try await createAndImportCertificate(
                        bundleId: bundleId,
                        certType: "MAC_INSTALLER_DISTRIBUTION",
                        filePrefix: "installer",
                        csrCN: "Mac Installer Distribution",
                        ascService: ascService,
                        emit: emit
                    )
                    state.installerCertificateId = installerCertId
                }
                try saveSigningState(state, bundleId: bundleId)
            }
        }

        // 3. Provisioning profile
        let profileUUID: String
        let profileExt = isMacOS ? "provisionprofile" : "mobileprovision"
        let profilesDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/MobileDevice/Provisioning Profiles")

        if let existing = state.profileUUID,
           fm.fileExists(atPath: profilesDir.appendingPathComponent("\(existing).\(profileExt)").path) {
            emit("Provisioning profile already installed: \(existing)")
            profileUUID = existing

            // Recover team ID from installed profile if missing
            if state.teamId == nil && teamId == nil {
                let profilePath = profilesDir.appendingPathComponent("\(existing).\(profileExt)").path
                if let extractedTeamId = Self.extractTeamId(from: profilePath) {
                    state.teamId = extractedTeamId
                    try saveSigningState(state, bundleId: bundleId)
                    emit("Extracted team ID from installed profile: \(extractedTeamId)")
                }
            }
        } else {
            if state.profileUUID != nil {
                emit("Provisioning profile missing from disk, re-downloading...")
                state.profileUUID = nil
                state.profileName = nil
                try saveSigningState(state, bundleId: bundleId)
            }
            emit("Creating provisioning profile (type: \(profileType))...")
            let profileName = "\(bundleId) \(isMacOS ? "Mac " : "")App Store"
            let profile: ASCProfile
            do {
                profile = try await ascService.createProfile(
                    name: profileName,
                    bundleIdResourceId: bundleIdResourceId,
                    certificateId: certificateId,
                    profileType: profileType
                )
            } catch let ascErr as ASCError where ascErr.isConflict {
                // Duplicate profile name — delete existing and retry
                emit("Profile name conflict. Deleting existing duplicates...")
                let existing = try await ascService.fetchProfiles(name: profileName)
                for old in existing {
                    try? await ascService.deleteProfile(id: old.id)
                    emit("Deleted duplicate profile: \(old.id)")
                }
                profile = try await ascService.createProfile(
                    name: profileName,
                    bundleIdResourceId: bundleIdResourceId,
                    certificateId: certificateId,
                    profileType: profileType
                )
            }
            emit("Created profile: \(profile.attributes.name)")

            // Decode and install the profile
            if let profileBase64 = profile.attributes.profileContent,
               let profileData = Data(base64Encoded: profileBase64) {

                // Extract UUID from the profile plist
                let uuid = profile.attributes.uuid ?? UUID().uuidString

                try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
                let profilePath = profilesDir.appendingPathComponent("\(uuid).\(profileExt)")
                try profileData.write(to: profilePath)
                emit("Installed profile at: \(profilePath.path)")
                profileUUID = uuid

                // Extract TeamIdentifier from the provisioning profile
                if state.teamId == nil && teamId == nil {
                    let extractedTeamId = Self.extractTeamId(from: profilePath.path)
                    if let extractedTeamId {
                        state.teamId = extractedTeamId
                        emit("Extracted team ID from profile: \(extractedTeamId)")
                    }
                }
            } else {
                profileUUID = profile.attributes.uuid ?? profile.id
            }

            state.profileUUID = profileUUID
            state.profileName = profile.attributes.name
            try saveSigningState(state, bundleId: bundleId)
        }

        // 4. Configure Xcode project
        let resolvedTeamId = teamId ?? state.teamId ?? ""
        if !resolvedTeamId.isEmpty {
            emit("Configuring pbxproj with team \(resolvedTeamId)...")
            try configurePbxproj(
                projectPath: projectPath,
                teamId: resolvedTeamId,
                bundleId: bundleId,
                scheme: scheme,
                configuration: configuration ?? "Release"
            )
            state.teamId = resolvedTeamId
            try saveSigningState(state, bundleId: bundleId)
            emit("Xcode project configured")
        } else {
            emit("Warning: no teamId provided — skipping pbxproj configuration")
        }

        return SigningResult(
            bundleIdResourceId: bundleIdResourceId,
            certificateId: certificateId,
            installerCertificateId: state.installerCertificateId,
            profileUUID: profileUUID,
            teamId: resolvedTeamId,
            log: log
        )
    }

    /// Generate a CSR, create a certificate via ASC API, and import to keychain.
    private func createAndImportCertificate(
        bundleId: String,
        certType: String,
        filePrefix: String,
        csrCN: String,
        ascService: AppStoreConnectService,
        emit: (String) -> Void
    ) async throws -> String {
        let signingDir = BlitzPaths.signing(bundleId: bundleId)
        try fm.createDirectory(at: signingDir, withIntermediateDirectories: true)

        let keyPath = signingDir.appendingPathComponent("\(filePrefix).key").path
        let csrPath = signingDir.appendingPathComponent("\(filePrefix).csr").path

        // Generate private key
        try await ProcessRunner.run("openssl", arguments: [
            "genrsa", "-out", keyPath, "2048"
        ], timeout: 30)
        emit("Generated RSA private key (\(filePrefix))")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)

        // Generate CSR
        try await ProcessRunner.run("openssl", arguments: [
            "req", "-new", "-key", keyPath, "-out", csrPath,
            "-subj", "/CN=\(csrCN)/O=Blitz/C=US"
        ], timeout: 30)
        let csrContent = try String(contentsOfFile: csrPath, encoding: .utf8)
        emit("Generated CSR (\(filePrefix))")

        // Create certificate via API
        let cert = try await ascService.createCertificate(csrContent: csrContent, type: certType)
        emit("Created \(certType) certificate: \(cert.id)")

        // Decode certificate content and import to keychain
        if let certBase64 = cert.attributes.certificateContent,
           let certData = Data(base64Encoded: certBase64) {
            let derPath = signingDir.appendingPathComponent("\(filePrefix).cer").path
            try certData.write(to: URL(fileURLWithPath: derPath))

            // Convert DER to PEM
            let pemPath = signingDir.appendingPathComponent("\(filePrefix).pem").path
            try await ProcessRunner.run("openssl", arguments: [
                "x509", "-inform", "DER", "-in", derPath, "-out", pemPath
            ], timeout: 30)

            // Create p12 for keychain import — use legacy algorithms (PBE-SHA1-3DES)
            // and a real password; OpenSSL 3.x defaults to AES-256-CBC which macOS
            // security cannot import, and empty passwords also fail.
            let p12Path = signingDir.appendingPathComponent("\(filePrefix).p12").path
            let p12Pass = "blitz-\(bundleId.hashValue & 0x7FFFFFFF)"
            try await ProcessRunner.run("openssl", arguments: [
                "pkcs12", "-export",
                "-inkey", keyPath, "-in", pemPath,
                "-out", p12Path, "-passout", "pass:\(p12Pass)",
                "-certpbe", "PBE-SHA1-3DES",
                "-keypbe", "PBE-SHA1-3DES",
                "-macalg", "SHA1"
            ], timeout: 30)

            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12Path)

            // Import to keychain
            try await ProcessRunner.run("security", arguments: [
                "import", p12Path, "-k",
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path,
                "-P", p12Pass, "-T", "/usr/bin/codesign",
                "-T", "/usr/bin/security"
            ], timeout: 30)
            emit("Imported \(certType) certificate to keychain")
        }

        return cert.id
    }

    /// Extract TeamIdentifier from an installed .mobileprovision file using `security cms`
    private static func extractTeamId(from profilePath: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["cms", "-D", "-i", profilePath]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plistStr = String(data: data, encoding: .utf8),
              let plistData = plistStr.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let teamIds = plist["TeamIdentifier"] as? [String],
              let teamId = teamIds.first else {
            return nil
        }
        return teamId
    }

    /// Update only the selected application's configurations, never its extensions.
    func updateBundleIdInPbxproj(
        projectPath: String, bundleId: String, scheme: String? = nil, configuration: String? = nil
    ) throws {
        try XcodeProjectIdentityEditor().update(
            projectPath: projectPath, bundleID: bundleId, scheme: scheme, configuration: configuration
        )
    }

    private func configurePbxproj(
        projectPath: String, teamId: String, bundleId: String, scheme: String?, configuration: String?
    ) throws {
        try XcodeProjectIdentityEditor().update(
            projectPath: projectPath, bundleID: bundleId, scheme: scheme,
            configuration: configuration, teamID: teamId
        )
    }

    // MARK: - Build IPA

    struct BuildResult {
        let ipaPath: String  // .ipa for iOS, .pkg for macOS
        let archivePath: String
        let log: [String]
    }

    func buildIPA(
        projectPath: String,
        bundleId: String,
        teamId: String,
        scheme: String?,
        configuration: String?,
        platform: ProjectPlatform = .iOS,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> BuildResult {
        var log: [String] = []

        func emit(_ msg: String) {
            log.append(msg)
            onProgress(msg)
        }

        let projectURL = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath()
        let config = configuration ?? "Release"
        let selection = try XcodeProjectIdentityEditor().select(
            projectPath: projectPath, scheme: scheme, configuration: config
        )

        // Search for workspace/project in root and common subdirectories (ios/, macos/, etc.)
        let searchDirs: [URL] = {
            var dirs = [projectURL]
            let subdirNames = ["ios", "macos", "apple"]
            for name in subdirNames {
                let sub = projectURL.appendingPathComponent(name)
                if fm.fileExists(atPath: sub.path) { dirs.append(sub) }
            }
            return dirs
        }()

        func findXcodeFiles(ext: String) -> [URL] {
            for dir in searchDirs {
                let matches = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                    .filter { $0.pathExtension == ext } ?? []
                if !matches.isEmpty { return matches }
            }
            return []
        }

        var workspaces = findXcodeFiles(ext: "xcworkspace")
        let xcodeprojs = [selection.projectURL]

        // Determine the directory containing the Xcode project (for pod install / build cwd)
        let xcodeDir: String = workspaces.first?.deletingLastPathComponent().path
            ?? xcodeprojs.first?.deletingLastPathComponent().path
            ?? projectPath

        // Run pod install if Podfile exists but no workspace
        let podfilePath = URL(fileURLWithPath: xcodeDir).appendingPathComponent("Podfile").path
        if workspaces.isEmpty && fm.fileExists(atPath: podfilePath) {
            emit("Running pod install...")
            try await ProcessRunner.run("pod", arguments: ["install"],
                                       currentDirectory: xcodeDir, timeout: 300)
            emit("pod install complete")
            // Re-check workspaces after pod install
            workspaces = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: xcodeDir), includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "xcworkspace" } ?? []
        }

        guard workspaces.count <= 1 else {
            throw XcodeProjectIdentityEditor.IdentityError(message: "Multiple workspaces were found. Open the intended workspace directory before archiving.")
        }
        let useWorkspace = !workspaces.isEmpty
        let buildTarget = useWorkspace
            ? workspaces[0].path
            : (xcodeprojs.first?.path ?? "")

        guard !buildTarget.isEmpty else {
            throw ProcessRunner.ProcessError(
                command: "xcodebuild",
                exitCode: -1,
                stderr: "No .xcworkspace or .xcodeproj found in \(projectPath) or its ios/ subdirectory"
            )
        }

        emit("Found Xcode project: \(buildTarget)")

        // An explicit scheme (or the sole application target's autogenerated
        // scheme) is safer than taking the first item returned by xcodebuild.
        let resolvedScheme = scheme ?? selection.targetName
        let destination = platform == .macOS ? "generic/platform=macOS" : "generic/platform=iOS"
        let resolvedSettings = try await ProcessRunner.run("xcodebuild", arguments: [
            useWorkspace ? "-workspace" : "-project", buildTarget,
            "-scheme", resolvedScheme, "-configuration", config,
            "-destination", destination, "-showBuildSettings", "-json"
        ], currentDirectory: xcodeDir, timeout: 60)
        try XcodeProjectIdentityEditor.validateResolvedBuildSettings(
            Data(resolvedSettings.utf8), targetName: selection.targetName, expectedBundleID: bundleId,
            projectURL: selection.projectURL
        )

        emit("Building scheme '\(resolvedScheme)' (\(config))...")

        // Load signing state so we can use manual distribution signing in both archive + export
        let signingState = loadSigningState(bundleId: bundleId)
        let profileRef = signingState.profileName ?? signingState.profileUUID ?? ""

        guard !profileRef.isEmpty else {
            throw ProcessRunner.ProcessError(
                command: "app_store_build",
                exitCode: -1,
                stderr: "No provisioning profile found for \(bundleId). Run app_store_setup_signing first (it will auto-generate a distribution certificate and profile)."
            )
        }

        let isMac = platform == .macOS

        // Archive with automatic/dev signing — no signing overrides on the command line,
        // because xcodebuild build settings apply globally to ALL targets including SPM
        // dependencies, which don't support provisioning profiles or manual signing.
        // The exportArchive step below re-signs with distribution cert + profile.
        let archivePath = NSTemporaryDirectory() + "BlitzArchive-\(UUID().uuidString).xcarchive"
        let archiveArgs = [
            useWorkspace ? "-workspace" : "-project",
            buildTarget,
            "-scheme", resolvedScheme,
            "-configuration", config,
            "-destination", destination,
            "-archivePath", archivePath,
            "archive"
        ]

        let archiveOutput = ProcessOutputCollector()
        let managed = ProcessRunner.stream(
            "xcodebuild",
            arguments: archiveArgs,
            currentDirectory: xcodeDir,
            onStdout: { line in
                onProgress(line)
                archiveOutput.appendStdout(line)
            },
            onStderr: { line in
                onProgress(line)
                archiveOutput.appendStderr(line)
            }
        )

        if let launchErr = managed.launchError {
            throw ProcessRunner.ProcessError(
                command: "xcodebuild archive",
                exitCode: -1,
                stderr: "Failed to launch xcodebuild: \(launchErr.localizedDescription)"
            )
        }

        await managed.waitUntilExit()

        guard managed.process.terminationStatus == 0 else {
            let stderrSummary = archiveOutput.summary
            throw ProcessRunner.ProcessError(
                command: "xcodebuild archive",
                exitCode: managed.process.terminationStatus,
                stderr: stderrSummary.isEmpty ? "Archive failed with exit code \(managed.process.terminationStatus)" : stderrSummary
            )
        }
        emit("Archive succeeded: \(archivePath)")

        // Generate ExportOptions.plist
        // app-store-connect produces a .pkg for macOS; app-store produces an .ipa for iOS
        let exportOptionsPath = NSTemporaryDirectory() + "ExportOptions-\(UUID().uuidString).plist"
        var exportOptions: [String: Any] = [
            "method": isMac ? "app-store-connect" : "app-store",
            "teamID": teamId,
            "signingStyle": "manual",
            "signingCertificate": "Apple Distribution",
            "uploadSymbols": true,
            "manageAppVersionAndBuildNumber": false
        ]
        if !profileRef.isEmpty {
            exportOptions["provisioningProfiles"] = [bundleId: profileRef]
        }
        if isMac {
            // installerSigningCertificate tells xcodebuild to produce a signed .pkg
            exportOptions["installerSigningCertificate"] = "3rd Party Mac Developer Installer"
        }
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: exportOptions,
            format: .xml,
            options: 0
        )
        try plistData.write(to: URL(fileURLWithPath: exportOptionsPath))
        emit("Generated ExportOptions.plist")

        // Export IPA
        let exportPath = NSTemporaryDirectory() + "BlitzExport-\(UUID().uuidString)"
        let exportOutput = ProcessOutputCollector()
        let exportManaged = ProcessRunner.stream(
            "xcodebuild",
            arguments: [
                "-exportArchive",
                "-archivePath", archivePath,
                "-exportPath", exportPath,
                "-exportOptionsPlist", exportOptionsPath,
                "-allowProvisioningUpdates"
            ],
            currentDirectory: xcodeDir,
            onStdout: { line in
                onProgress(line)
                exportOutput.appendStdout(line)
            },
            onStderr: { line in
                onProgress(line)
                exportOutput.appendStderr(line)
            }
        )

        if let launchErr = exportManaged.launchError {
            throw ProcessRunner.ProcessError(
                command: "xcodebuild -exportArchive",
                exitCode: -1,
                stderr: "Failed to launch xcodebuild: \(launchErr.localizedDescription)"
            )
        }

        await exportManaged.waitUntilExit()

        guard exportManaged.process.terminationStatus == 0 else {
            var stderrSummary = exportOutput.summary

            // Extract real error from IDEDistribution log if available
            // xcodebuild prints "Created bundle at path <log_path>" on export failure
            if let logDir = exportOutput.lastLogBundlePath {
                let errorLogPath = logDir + "/IDEDistribution.standard-log.txt"
                if let logContent = try? String(contentsOfFile: errorLogPath, encoding: .utf8) {
                    // Extract error lines from the log
                    let errorLines = logContent.components(separatedBy: "\n")
                        .filter {
                            let lowercased = $0.lowercased()
                            return lowercased.contains("error:")
                                || lowercased.contains("error domain")
                                || lowercased.contains("no profiles")
                                || lowercased.contains("doesn't match")
                                || lowercased.contains("provisioning")
                                || lowercased.contains("asset catalog")
                                || lowercased.contains("appicon")
                                || lowercased.contains(".appiconset")
                        }
                    if !errorLines.isEmpty {
                        stderrSummary += "\n\n--- Distribution Log Errors ---\n" + errorLines.joined(separator: "\n")
                    }
                }
            }

            throw ProcessRunner.ProcessError(
                command: "xcodebuild -exportArchive",
                exitCode: exportManaged.process.terminationStatus,
                stderr: stderrSummary.isEmpty ? "Export failed with exit code \(exportManaged.process.terminationStatus)" : stderrSummary
            )
        }

        // Find the exported artifact (.pkg for macOS, .ipa for iOS)
        let exportedFiles = try fm.contentsOfDirectory(at: URL(fileURLWithPath: exportPath),
                                                        includingPropertiesForKeys: nil)
        let expectedExt = isMac ? "pkg" : "ipa"
        let artifacts = exportedFiles.filter { $0.pathExtension == expectedExt }
        guard artifacts.count == 1, let artifactURL = artifacts.first else {
            throw ProcessRunner.ProcessError(
                command: "xcodebuild -exportArchive",
                exitCode: -1,
                stderr: "No .\(expectedExt) found in export directory: \(exportPath)"
            )
        }

        let archiveMetadata = try BuildArtifactMetadata.readArchive(at: URL(fileURLWithPath: archivePath), platform: platform)
        try archiveMetadata.validate(bundleID: bundleId, platform: platform)
        let artifactMetadata = try await BuildArtifactMetadata.read(artifactURL: artifactURL, platform: platform)
        try artifactMetadata.validateExportMatchesArchive(archiveMetadata)
        emit("Verified \(artifactMetadata.shortVersion) (\(artifactMetadata.buildNumber)) in archive and exported artifact.")
        emit("\(expectedExt.uppercased()) exported: \(artifactURL.path)")

        return BuildResult(
            ipaPath: artifactURL.path,
            archivePath: archivePath,
            log: log
        )
    }

    // MARK: - Upload to TestFlight

    struct HelperBuildUploadResult: Decodable {
        let uploadId: String
        let fileId: String
        let fileName: String?
        let fileSize: Int64?
        let uploaded: Bool?
    }

    struct UploadResult {
        let buildVersion: String?
        let processingState: String?
        let uploadId: String?
        let fileId: String?
        let uploadCommitted: Bool
        let log: [String]
    }

    static func buildsUploadCommandArguments(
        appId: String,
        artifactPath: String,
        platform: ProjectPlatform,
        skipPolling: Bool,
        metadata: BuildArtifactMetadata? = nil
    ) throws -> [String] {
        let isMacArtifact = platform == .macOS
        guard URL(fileURLWithPath: artifactPath).pathExtension.lowercased() == (isMacArtifact ? "pkg" : "ipa") else {
            throw BuildArtifactMetadata.ValidationError(message: "Artifact extension does not match the upload platform.")
        }
        if isMacArtifact && metadata == nil {
            throw BuildArtifactMetadata.ValidationError(message: "PKG upload requires its verified version and build number.")
        }
        var args = ["builds", "upload", "--app", appId]
        if isMacArtifact {
            args += ["--pkg", artifactPath, "--platform", "MAC_OS"]
        } else {
            args += ["--ipa", artifactPath, "--platform", "IOS"]
        }
        if let metadata {
            guard metadata.platform == platform else {
                throw BuildArtifactMetadata.ValidationError(message: "Artifact metadata does not match the upload platform.")
            }
            args += ["--version", metadata.shortVersion, "--build-number", metadata.buildNumber]
        }
        if skipPolling {
            args += ["--verify-timeout", helperUploadVerifyTimeout]
        } else {
            args.append("--wait")
        }
        args += ["--output", "json"]
        return args
    }

    static func parseBuildUploadCLIResult(from stdout: String) throws -> HelperBuildUploadResult {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProcessRunner.ProcessError(
                command: "asc builds upload",
                exitCode: -1,
                stderr: "ASC helper returned no JSON output for the build upload."
            )
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw ProcessRunner.ProcessError(
                command: "asc builds upload",
                exitCode: -1,
                stderr: "ASC helper returned non-UTF8 build upload output."
            )
        }
        do {
            return try JSONDecoder().decode(HelperBuildUploadResult.self, from: data)
        } catch {
            throw ProcessRunner.ProcessError(
                command: "asc builds upload",
                exitCode: -1,
                stderr: "Failed to decode ASC helper build upload output: \(error.localizedDescription)"
            )
        }
    }

    static func validatedBuildUploadCLIResult(from stdout: String) throws -> HelperBuildUploadResult {
        let result = try parseBuildUploadCLIResult(from: stdout)
        guard result.uploaded == true else {
            throw ProcessRunner.ProcessError(
                command: "asc builds upload",
                exitCode: -1,
                stderr: "App Store Connect reserved upload \(result.uploadId), but file \(result.fileId) was not marked uploaded."
            )
        }
        return result
    }

    func uploadToTestFlight(
        ipaPath: String,
        keyId: String,
        issuerId: String,
        privateKeyPEM: String,
        appId: String?,
        ascService: AppStoreConnectService?,
        skipPolling: Bool,
        platform: ProjectPlatform = .iOS,
        metadata: BuildArtifactMetadata,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> UploadResult {
        var log: [String] = []

        func emit(_ msg: String) {
            log.append(msg)
            onProgress(msg)
        }

        if let appId, let ascService {
            emit("Uploading \(platform == .macOS ? "PKG" : "IPA") to App Store Connect...")
            let cliArgs = try Self.buildsUploadCommandArguments(
                appId: appId,
                artifactPath: ipaPath,
                platform: platform,
                skipPolling: skipPolling,
                metadata: metadata
            )
            let cliResult = try await ascService.cliExec(
                args: cliArgs,
                responseTimeoutSeconds: skipPolling ? nil : Self.helperUploadWaitResponseTimeoutSeconds
            )

            let stderrLines = cliResult.stderr
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            log.append(contentsOf: stderrLines)

            guard cliResult.exitCode == 0 else {
                let stderrSummary = stderrLines.isEmpty
                    ? cliResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    : stderrLines.joined(separator: "\n")
                throw ProcessRunner.ProcessError(
                    command: "asc builds upload",
                    exitCode: Int32(cliResult.exitCode),
                    stderr: stderrSummary.isEmpty
                        ? "Build upload failed with exit code \(cliResult.exitCode)"
                        : stderrSummary
                )
            }

            let helperResult = try Self.validatedBuildUploadCLIResult(from: cliResult.stdout)

            emit("Upload committed in App Store Connect.")
            return UploadResult(
                buildVersion: nil,
                processingState: skipPolling ? "UPLOAD_COMMITTED" : nil,
                uploadId: helperResult.uploadId,
                fileId: helperResult.fileId,
                uploadCommitted: true,
                log: log
            )
        }

        throw BuildArtifactMetadata.ValidationError(message: "Upload requires a captured App Store app and authenticated ASC service. Reopen the app before retrying.")
    }
}
