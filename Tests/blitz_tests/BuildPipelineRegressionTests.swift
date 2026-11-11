import Testing
import Foundation
@testable import Blitz

@Test func archiveDestinationKeepsNativeMacAndCatalystDistinct() throws {
    #expect(try BuildPipelineService.archiveDestination(platform: .iOS, configured: nil) == "generic/platform=iOS")
    #expect(try BuildPipelineService.archiveDestination(platform: .macOS, configured: nil) == "generic/platform=macOS")
    #expect(try BuildPipelineService.archiveDestination(platform: .macOS,
        configured: "generic/platform=macOS,variant=Mac Catalyst") == "generic/platform=macOS,variant=Mac Catalyst")
    for value in ["", "generic/platform=macOS", "generic/platform=macOS,variant=Mac Catalyst", "platform=iOS,id=device", "generic/platform=iOS Simulator", "generic/platform=iOS\n"] {
        #expect(throws: Error.self) { try BuildPipelineService.archiveDestination(platform: .iOS, configured: value) }
    }
    for value in ["generic/platform=iOS", "platform=macOS,id=host", "generic/platform=macOS,arch=arm64", "generic/platform=macOS; echo bad"] {
        #expect(throws: Error.self) { try BuildPipelineService.archiveDestination(platform: .macOS, configured: value) }
    }
}

@Test func signingCacheSeparatesAccountsPlatformsAndBundlesWithoutUsingLegacyState() throws {
    let root = URL(fileURLWithPath: "/private/tmp/signing-fixture")
    func directory(_ bundle: String = "org.example.Shared", _ platform: ProjectPlatform = .iOS, _ account: String = "issuer:key") throws -> URL {
        try BuildPipelineService.signingCacheDirectory(bundleId: bundle, platform: platform, accountKey: account, root: root)
    }
    let ios = try directory()
    #expect(ios == (try directory()))
    #expect(ios != (try directory("org.example.Shared", .macOS)))
    #expect(ios != (try directory("org.example.Shared", .iOS, "other:key")))
    #expect(ios != (try directory("org.example.Other")))
    #expect(ios.deletingLastPathComponent().lastPathComponent == "scopes")
    #expect(ios.appendingPathComponent("signing-state.json") != root.appendingPathComponent("org.example.Shared/signing-state.json"))
    #expect(!ios.path.contains("issuer:key"))
    #expect(throws: Error.self) { try directory("../../escape") }
    #expect(throws: Error.self) { try directory("org.example.Shared", .iOS, "") }
}

@Test func processOutputCollectorPrioritizesAppIconFailures() {
    let collector = ProcessOutputCollector(maxStoredLines: 40, maxSummaryLines: 12)

    collector.appendStdout("CompileAssetCatalogVariant thinned /tmp/Assets.car")
    collector.appendStderr("/tmp/App.xcassets: error: The app icon set named \"AppIcon\" did not have any applicable content.")
    collector.appendStdout("** ARCHIVE FAILED **")

    let summary = collector.summary

    #expect(summary.contains("CompileAssetCatalogVariant"))
    #expect(summary.contains("app icon set named \"AppIcon\""))
}

@Test func artifactMetadataParsesBuildAndVersionFromInfoPlist() {
    let plistXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleShortVersionString</key>
        <string>1.0</string>
        <key>CFBundleVersion</key>
        <string>42</string>
        <key>ITSAppUsesNonExemptEncryption</key>
        <false/>
    </dict>
    </plist>
    """

    let metadata = MCPExecutor.artifactMetadata(fromPlistXML: plistXML)

    #expect(metadata?.shortVersion == "1.0")
    #expect(metadata?.buildNumber == "42")
    #expect(metadata?.hasEncryptionDeclaration == true)
}

@Test func buildUploadProcessingHintDecodesKnownAppIconErrorCodes() {
    let hint = MCPExecutor.buildUploadProcessingHint(codes: ["90023", "90713", "90022"])

    #expect(hint?.contains("app icon payload") == true)
    #expect(hint?.contains("1024x1024 App Store icon") == true)
}

@Test func buildsUploadCommandArgumentsUseHelperUploadPath() throws {
    let args = try BuildPipelineService.buildsUploadCommandArguments(
        appId: "6761669298",
        artifactPath: "/tmp/NotesApp.ipa",
        platform: .iOS,
        skipPolling: true
    )

    #expect(Array(args.prefix(3)) == ["builds", "upload", "--app"])
    #expect(args.contains("--ipa"))
    #expect(args.contains("--verify-timeout"))
    #expect(!args.contains("altool"))
}

@Test func validatedBuildUploadCLIResultRejectsUnuploadedReservations() {
    let stdout = """
    {"uploadId":"upload-1","fileId":"file-1","uploaded":false}
    """

    do {
        _ = try BuildPipelineService.validatedBuildUploadCLIResult(from: stdout)
        Issue.record("Expected helper upload validation to reject an unuploaded reservation")
    } catch {
        #expect(error.localizedDescription.contains("was not marked uploaded"))
    }
}
