import Foundation
import Testing
@testable import Blitz

private func importFixture() -> IrisSession {
    IrisSession(cookies: [
        .init(name: "myacinfo", value: "test-cookie", domain: ".apple.com", path: "/"),
        .init(name: "unrelated", value: "not-exported", domain: "example.org", path: "/")
    ], email: "test@example.com", capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        providerId: 123, publicProviderId: "provider-test", providerName: "Test Team")
}

@Test func webSessionImportUsesGuardedRPCAndPrivateTemporaryFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let importer = ASCWebSessionCLIImporter(helperPath: "/test/ascd", environment: ["ASC_WEB_SESSION_CACHE_DIR": "/test/cache"], temporaryDirectory: root) { path, args, env, directory in
        #expect(path == "/test/ascd")
        #expect(args.isEmpty) // Credentials and --overwrite never appear in argv.
        #expect(env["ASC_BYPASS_KEYCHAIN"] == "1")
        #expect(env["ASC_WEB_SESSION_CACHE_DIR"] == "/test/cache")
        let file = directory.appendingPathComponent("request.json")
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        let request = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(request["method"] as? String == "web.session.import")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["expectedProviderId"] as? String == "provider-test")
        let json = try #require(params["bundle"] as? [String: Any])
        #expect(json["kind"] as? String == "asc-web-session")
        #expect(json["appleId"] as? String == "test@example.com")
        let cookies = try #require(json["cookies"] as? [[String: Any]])
        #expect(cookies.count == 4)
        #expect(cookies.allSatisfy { $0["name"] as? String == "myacinfo" })
        #expect(cookies.allSatisfy { ($0["domain"] as? String) == URL(string: $0["url"] as? String ?? "")?.host })
        let receipt: [String: Any] = ["id": try #require(request["id"] as? String), "result": [
            "outcome": "existingPreserved", "reason": "existing_session_stronger",
            "appleId": "test@example.com", "providerId": "provider-test", "developerTeamId": "TEAM",
            "asc": ["status": "verified", "reason": "session_verified"],
            "developerPortal": ["status": "verified", "reason": "team_verified"]]]
        return (0, try JSONSerialization.data(withJSONObject: receipt))
    }
    let result = try await importer.importSession(importFixture())
    #expect(result.outcome == "existingPreserved")
    #expect(result.satisfies(requireDeveloperPortal: true))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func webSessionBundleNarrowsAndDeduplicatesCookieDomains() throws {
    var session = importFixture()
    session.cookies.append(.init(name: "myacinfo", value: "specific", domain: "appstoreconnect.apple.com", path: "/"))
    let data = try ASCWebSessionCLIImporter.bundleData(for: session)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cookies = try #require(json["cookies"] as? [[String: Any]])
    #expect(cookies.count == 4)
    let asc = try #require(cookies.first { $0["url"] as? String == "https://appstoreconnect.apple.com/" })
    #expect(asc["value"] as? String == "specific")
    #expect(asc["domain"] as? String == "appstoreconnect.apple.com")
}

@Test func webSessionBundleIsAcceptedByPinnedASCParserOffline() throws {
    guard let helper = ProcessInfo.processInfo.environment["BLITZ_TEST_ASCD"] else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("fixture.json")
    try ASCWebSessionCLIImporter.bundleData(for: importFixture()).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: helper)
    // Omit --validate only in this isolated parser test with fictitious cookies.
    process.arguments = ["__ascd_run_cli__", "web", "auth", "import", "--file", file.path, "--overwrite"]
    var env = ProcessInfo.processInfo.environment
    env["ASC_WEB_SESSION_CACHE_DIR"] = root.appendingPathComponent("cache").path
    env["ASC_WEB_SESSION_CACHE_BACKEND"] = "file"
    env["ASC_BYPASS_KEYCHAIN"] = "1"
    env["ASC_TELEMETRY_DISABLED"] = "1"
    env["ASC_CONFIG_PATH"] = root.appendingPathComponent("no-config.json").path
    process.environment = env
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache/last.json").path))
}

@Test(arguments: [Int32(1), Int32(0)]) func webSessionImportNeverAcceptsRejectionOrMismatchedAccount(exit: Int32) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let importer = ASCWebSessionCLIImporter(helperPath: "/test/ascd", temporaryDirectory: root) { _, _, _, directory in
        let request = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("request.json"))) as? [String: Any])
        let receipt: [String: Any] = ["id": try #require(request["id"] as? String), "result": [
            "outcome": "imported", "reason": "session_verified", "appleId": "other@example.com", "providerId": "provider-test",
            "asc": ["status": "verified", "reason": "session_verified"],
            "developerPortal": ["status": "unverified", "reason": "missing_portal"]]]
        return (exit, try JSONSerialization.data(withJSONObject: receipt))
    }
    await #expect(throws: ASCWebSessionCLIImporter.ImportError.self) {
        try await importer.importSession(importFixture())
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func webSessionImportRejectsMissingIdentityBeforeLaunchingHelper() async {
    var session = importFixture()
    session.email = nil
    let importer = ASCWebSessionCLIImporter(helperPath: "/test/ascd") { _, _, _, _ in
        Issue.record("Must not launch a helper for an unidentified session")
        return (0, Data())
    }
    await #expect(throws: ASCWebSessionCLIImporter.ImportError.self) { try await importer.importSession(session) }
}

@Test func webSessionImportRemovesTemporaryCredentialsOnCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let importer = ASCWebSessionCLIImporter(helperPath: "/test/ascd", temporaryDirectory: root) { _, _, _, _ in
        throw CancellationError()
    }
    await #expect(throws: CancellationError.self) { try await importer.importSession(importFixture()) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func webSessionImportRequiresFreshProviderIdentityBeforeLaunchingHelper() async {
    var session = importFixture()
    session.publicProviderId = nil
    let importer = ASCWebSessionCLIImporter(helperPath: "/test/ascd") { _, _, _, _ in
        Issue.record("Must not infer the provider from cached credentials")
        return (0, Data())
    }
    await #expect(throws: ASCWebSessionCLIImporter.ImportError.self) { try await importer.importSession(session) }
}

@Test func webSessionBundleIncludesDeveloperPathCookiesWithoutChangingTheirPath() throws {
    var session = importFixture()
    session.cookies += [
        .init(name: "portal", value: "root", domain: "developer.apple.com", path: "/"),
        .init(name: "portal", value: "services", domain: "developer.apple.com", path: "/services-account"),
        .init(name: "portal", value: "unrelated", domain: "developer.apple.com.example.org", path: "/")
    ]
    let json = try #require(JSONSerialization.jsonObject(with: ASCWebSessionCLIImporter.bundleData(for: session)) as? [String: Any])
    let cookies = try #require(json["cookies"] as? [[String: Any]])
    let portal = cookies.filter { $0["name"] as? String == "portal" }
    #expect(portal.count == 2)
    #expect(Set(portal.compactMap { $0["path"] as? String }) == ["/", "/services-account"])
    #expect(portal.allSatisfy { $0["url"] as? String == "https://developer.apple.com/" })
}

@Test func webLoginCapabilityDoesNotConfuseASCWithDeveloperPortal() {
    var evidence = ASCWebSessionImportEvidence(outcome: "imported", reason: "imported", appleId: "a@example.com", providerId: "provider",
        asc: .init(status: .verified, reason: "ok"), developerPortal: .init(status: .unverified, reason: "missing"))
    #expect(evidence.satisfies(requireDeveloperPortal: false))
    #expect(!evidence.satisfies(requireDeveloperPortal: true))
    evidence = .init(outcome: "conflict", reason: "cache_changed", appleId: "a@example.com", providerId: "provider",
        asc: .init(status: .verified, reason: "ok"), developerPortal: .init(status: .verified, reason: "ok"))
    #expect(!evidence.satisfies(requireDeveloperPortal: false))
    #expect(!evidence.satisfies(requireDeveloperPortal: true))
}

@Test func nativeSessionRejectsEvidenceFromAnotherAccountOrProvider() {
    var session = importFixture()
    session.importEvidence = .init(outcome: "imported", reason: "ok", appleId: "test@example.com", providerId: "provider-test",
        asc: .init(status: .verified, reason: "ok"), developerPortal: .init(status: .unverified, reason: "missing"))
    #expect(session.hasVerifiedImport())
    #expect(!session.hasVerifiedImport(requireDeveloperPortal: true))
    session.publicProviderId = "other-provider"
    #expect(!session.hasVerifiedImport())
    session.publicProviderId = "provider-test"
    session.email = "other@example.com"
    #expect(!session.hasVerifiedImport())
}

@MainActor @Test func iapReaderUsesNativeSessionAndRejectsMismatchedImportEvidence() {
    let manager = ASCManager()
    var session = importFixture()
    session.importEvidence = .init(outcome: "imported", reason: "ok", appleId: "test@example.com", providerId: "provider-test",
        asc: .init(status: .verified, reason: "ok"), developerPortal: .init(status: .unverified, reason: "missing"))
    manager.irisSession = session
    #expect(manager.ascWebSessionCookieHeader()?.contains("myacinfo=test-cookie") == true)
    session.publicProviderId = "another-provider"
    manager.irisSession = session
    #expect(manager.ascWebSessionCookieHeader() == nil)
}

@Test func portalReceiptNeedsAnExplicitVerifiedTeam() {
    var receipt = ASCWebSessionImportEvidence(outcome: "existingPreserved", reason: "ok",
        appleId: "test@example.com", providerId: "provider-test",
        asc: .init(status: .verified, reason: "ok"), developerPortal: .init(status: .verified, reason: "ok"))
    #expect(receipt.satisfies(requireDeveloperPortal: false))
    #expect(!receipt.satisfies(requireDeveloperPortal: true))
    receipt.developerTeamId = "  "
    #expect(!receipt.satisfies(requireDeveloperPortal: true))
    receipt.developerTeamId = "EXACTTEAM"
    #expect(receipt.satisfies(requireDeveloperPortal: true))
}
