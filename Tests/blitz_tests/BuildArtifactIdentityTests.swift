import Foundation
import Testing
@testable import Blitz

private func artifactPlist(platform: ProjectPlatform = .iOS, version: String = "1.2", build: String = "10.4.3", encryption: Any? = true) throws -> Data {
    var plist: [String: Any] = ["CFBundleIdentifier": "org.example.MixedCase", "CFBundleShortVersionString": version,
                              "CFBundleVersion": build, "CFBundleSupportedPlatforms": [platform == .macOS ? "MacOSX" : "iPhoneOS"]]
    plist["ITSAppUsesNonExemptEncryption"] = encryption
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
}

private func artifactTestDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlitzArtifactTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func existingArtifactBuild(number: String, version: String, platform: String, appID: String = "app-1") throws -> ASCBuild {
    let data = try JSONSerialization.data(withJSONObject: [
        "id": "build-\(number)", "attributes": ["version": number, "processingState": "VALID"],
        "relationships": ["app": ["data": ["id": appID]]],
        "preReleaseVersion": ["id": "train-1", "attributes": ["version": version, "platform": platform]]
    ])
    return try JSONDecoder().decode(ASCBuild.self, from: data)
}

@Test func artifactMetadataPreservesRealEncryptionAndBundleCase() throws {
    let yes = try BuildArtifactMetadata.fromPlist(artifactPlist(), platform: .iOS)
    let no = try BuildArtifactMetadata.fromPlist(artifactPlist(encryption: false), platform: .iOS)
    let absent = try BuildArtifactMetadata.fromPlist(artifactPlist(encryption: nil), platform: .iOS)
    #expect(yes.bundleID == "org.example.MixedCase")
    #expect(yes.usesNonExemptEncryption == true)
    #expect(no.usesNonExemptEncryption == false)
    #expect(absent.usesNonExemptEncryption == nil)
    #expect(throws: (any Error).self) { try BuildArtifactMetadata.fromPlist(artifactPlist(encryption: "NO"), platform: .iOS) }
}

@Test func artifactIdentityRejectsWrongAppVersionPlatformAndMalformedBuild() throws {
    let metadata = try BuildArtifactMetadata.fromPlist(artifactPlist(), platform: .iOS)
    #expect(throws: (any Error).self) { try metadata.validate(bundleID: "org.example.Other", platform: .iOS) }
    #expect(throws: (any Error).self) { try metadata.validate(bundleID: metadata.bundleID, platform: .macOS) }
    #expect(throws: (any Error).self) { try metadata.validate(bundleID: metadata.bundleID, platform: .iOS, version: "1.3") }
    for build in ["0", "-1", "1.2.3.4", "1..3", "1e2", "١", "1 "] {
        #expect(throws: (any Error).self) { try BuildArtifactMetadata.fromPlist(artifactPlist(build: build), platform: .iOS) }
    }
    #expect(throws: (any Error).self) { try BuildArtifactMetadata.fromPlist(artifactPlist(platform: .macOS), platform: .iOS) }
}

@Test func exportedArtifactMustKeepArchiveVersionBuildAndEncryption() throws {
    let archive = try BuildArtifactMetadata.fromPlist(artifactPlist(), platform: .iOS)
    try archive.validateExportMatchesArchive(archive)
    for data in [try artifactPlist(build: "10.4.4"), try artifactPlist(version: "1.3"), try artifactPlist(encryption: false)] {
        let changed = try BuildArtifactMetadata.fromPlist(data, platform: .iOS)
        #expect(throws: (any Error).self) { try changed.validateExportMatchesArchive(archive) }
    }
}

@Test func artifactBuildNumbersCompareDottedComponentsWithoutIntegerOverflow() {
    #expect(BuildArtifactMetadata.compareNumbers("10.4.10", "10.4.9") == .orderedDescending)
    #expect(BuildArtifactMetadata.compareNumbers("00010.04", "10.4.0") == .orderedSame)
    #expect(BuildArtifactMetadata.compareNumbers("999999999999999999999", "10") == .orderedDescending)
    #expect(BuildArtifactMetadata.compareNumbers("10.4.2", "10.4.3") == .orderedAscending)
    #expect(BuildArtifactMetadata.compareNumbers("1..2", "1") == nil)
}

@Test func duplicateBuildChecksRespectPlatformAndVersionTrain() throws {
    let metadata = try BuildArtifactMetadata.fromPlist(artifactPlist(), platform: .iOS)
    let same = try existingArtifactBuild(number: "10.4.3", version: "1.2", platform: "IOS")
    let newer = try existingArtifactBuild(number: "10.4.10", version: "1.2", platform: "IOS")
    let incomparable = try existingArtifactBuild(number: "unknown", version: "1.2", platform: "IOS")
    #expect(throws: (any Error).self) { try MCPExecutor.validateBuildNumber(metadata, appID: "app-1", existing: [incomparable]) }
    #expect(throws: (any Error).self) { try MCPExecutor.validateBuildNumber(metadata, appID: "app-1", existing: [same]) }
    #expect(throws: (any Error).self) { try MCPExecutor.validateBuildNumber(metadata, appID: "app-1", existing: [newer]) }
    try MCPExecutor.validateBuildNumber(metadata, appID: "app-1", existing: [
        existingArtifactBuild(number: "99", version: "1.1", platform: "IOS"),
        existingArtifactBuild(number: "99", version: "1.2", platform: "MAC_OS")
    ])
    let mac = try BuildArtifactMetadata.fromPlist(artifactPlist(platform: .macOS), platform: .macOS)
    #expect(throws: (any Error).self) {
        try MCPExecutor.validateBuildNumber(mac, appID: "app-1", existing: [existingArtifactBuild(number: "99", version: "1.1", platform: "MAC_OS")])
    }
}

@Test func packageUploadRequiresAndPassesVerifiedVersionAndBuild() throws {
    let metadata = try BuildArtifactMetadata.fromPlist(artifactPlist(platform: .macOS), platform: .macOS)
    #expect(throws: (any Error).self) { try BuildPipelineService.buildsUploadCommandArguments(appId: "app-1", artifactPath: "/tmp/App.pkg", platform: .macOS, skipPolling: true) }
    let args = try BuildPipelineService.buildsUploadCommandArguments(appId: "app-1", artifactPath: "/tmp/App.pkg", platform: .macOS, skipPolling: true, metadata: metadata)
    #expect(args[try #require(args.firstIndex(of: "--version")) + 1] == "1.2")
    #expect(args[try #require(args.firstIndex(of: "--build-number")) + 1] == "10.4.3")
    #expect(args.contains("--pkg"))
    #expect(!args.contains("--ipa"))
}

@Test func ipaInspectionHandlesQuotesShellSyntaxAndBinaryPlists() async throws {
    let root = try artifactTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Payload/Bob's App.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try artifactPlist().write(to: app.appendingPathComponent("Info.plist"))
    let ipa = root.appendingPathComponent("Bob's $(touch NEVER_CREATED).ipa")
    try await ProcessRunner.run("/usr/bin/zip", arguments: ["-qr", ipa.path, "Payload"], currentDirectory: root.path)
    let metadata = try await BuildArtifactMetadata.read(artifactURL: ipa, platform: .iOS)
    #expect(metadata.buildNumber == "10.4.3")
    #expect(metadata.usesNonExemptEncryption == true)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("NEVER_CREATED").path))
    let otherApp = root.appendingPathComponent("Payload/Other.app")
    try FileManager.default.createDirectory(at: otherApp, withIntermediateDirectories: true)
    try artifactPlist().write(to: otherApp.appendingPathComponent("Info.plist"))
    try await ProcessRunner.run("/usr/bin/zip", arguments: ["-qr", ipa.path, "Payload"], currentDirectory: root.path)
    await #expect(throws: (any Error).self) { try await BuildArtifactMetadata.read(artifactURL: ipa, platform: .iOS) }
}

@Test func packageInspectionReadsActualPayloadWithoutInstalling() async throws {
    let root = try artifactTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = root.appendingPathComponent("payload")
    let app = payload.appendingPathComponent("Fixture.app/Contents")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try artifactPlist(platform: .macOS, encryption: false).write(to: app.appendingPathComponent("Info.plist"))
    let pkg = root.appendingPathComponent("Bob's App.pkg")
    try await ProcessRunner.run("/usr/bin/pkgbuild", arguments: ["--root", payload.path, "--identifier", "org.example.offline-artifact-fixture", "--version", "1.2", "--install-location", "/Applications", pkg.path])
    let distribution = root.appendingPathComponent("Distribution.pkg")
    try await ProcessRunner.run("/usr/bin/productbuild", arguments: ["--package", pkg.path, distribution.path])
    let componentMetadata = try await BuildArtifactMetadata.read(artifactURL: pkg, platform: .macOS)
    let metadata = try await BuildArtifactMetadata.read(artifactURL: distribution, platform: .macOS)
    #expect(metadata == componentMetadata)
    #expect(metadata.bundleID == "org.example.MixedCase")
    #expect(metadata.shortVersion == "1.2")
    #expect(metadata.buildNumber == "10.4.3")
    #expect(metadata.usesNonExemptEncryption == false)
}

@Test func pipelineOwnershipRejectsConcurrentStartAndReleasesWithoutVersionSelection() throws {
    var operation = BuildPipelineOperationState()
    let firstResult = operation.begin()
    let first = try #require(firstResult)
    let concurrent = operation.begin()
    #expect(concurrent == nil)
    let unrelatedFinish = operation.finish(UUID())
    #expect(!unrelatedFinish)
    #expect(operation.operationID == first)
    // Cleanup is tied to operation ownership, never to the currently selected version.
    let firstFinished = operation.finish(first)
    #expect(firstFinished)
    let secondResult = operation.begin()
    let second = try #require(secondResult)
    let staleFinish = operation.finish(first)
    #expect(!staleFinish)
    #expect(operation.operationID == second)
    let secondFinished = operation.finish(second)
    #expect(secondFinished)
}

@Test func artifactWithNoDeclaredPlatformIsRejected() throws {
    var plist = try #require(PropertyListSerialization.propertyList(from: artifactPlist(), format: nil) as? [String: Any])
    plist.removeValue(forKey: "CFBundleSupportedPlatforms")
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    #expect(throws: (any Error).self) { try BuildArtifactMetadata.fromPlist(data, platform: .iOS) }
}
