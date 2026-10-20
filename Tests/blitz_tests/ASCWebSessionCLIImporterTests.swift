import Foundation
import Testing
@testable import Blitz

private func importFixture() -> IrisSession {
    IrisSession(cookies: [
        .init(name: "myacinfo", value: "test-cookie", domain: ".apple.com", path: "/"),
        .init(name: "unrelated", value: "not-exported", domain: "example.org", path: "/")
    ], email: "test@example.com", capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
}

@Test func webSessionImportUsesOfficialValidationAndPrivateTemporaryFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let importer = ASCWebSessionCLIImporter(helperPath: "/test/ascd", environment: ["ASC_WEB_SESSION_CACHE_DIR": "/test/cache"], temporaryDirectory: root) { path, args, env, directory in
        #expect(path == "/test/ascd")
        #expect(args.prefix(4) == ["__ascd_run_cli__", "web", "auth", "import"])
        #expect(args.contains("--validate") && args.contains("--overwrite"))
        #expect(env["ASC_BYPASS_KEYCHAIN"] == "1")
        #expect(env["ASC_WEB_SESSION_CACHE_DIR"] == "/test/cache")
        let file = URL(fileURLWithPath: args[try #require(args.firstIndex(of: "--file")) + 1])
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["kind"] as? String == "asc-web-session")
        #expect(json["appleId"] as? String == "test@example.com")
        let cookies = try #require(json["cookies"] as? [[String: Any]])
        #expect(cookies.count == 3)
        #expect(cookies.allSatisfy { $0["name"] as? String == "myacinfo" })
        #expect(cookies.allSatisfy { ($0["domain"] as? String) == URL(string: $0["url"] as? String ?? "")?.host })
        return (0, Data(#"{"imported":true,"appleId":"test@example.com","cookieCount":3}"#.utf8))
    }
    try await importer.importSession(importFixture())
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func webSessionBundleNarrowsAndDeduplicatesCookieDomains() throws {
    var session = importFixture()
    session.cookies.append(.init(name: "myacinfo", value: "specific", domain: "appstoreconnect.apple.com", path: "/"))
    let data = try ASCWebSessionCLIImporter.bundleData(for: session)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cookies = try #require(json["cookies"] as? [[String: Any]])
    #expect(cookies.count == 3)
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
    let importer = ASCWebSessionCLIImporter(helperPath: "/test/ascd", temporaryDirectory: root) { _, _, _, _ in
        (exit, Data(#"{"imported":true,"appleId":"other@example.com","cookieCount":3}"#.utf8))
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
