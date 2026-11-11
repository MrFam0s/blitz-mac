import Foundation
import Testing
@testable import Blitz

private func manualReleaseProject(bundle: String = "org.example.MixedCase", platform: ProjectPlatform = .iOS) -> Project {
    var metadata = BlitzProjectMetadata(name: "App", type: .swift, bundleIdentifier: bundle)
    metadata.platform = platform
    return Project(id: "project", metadata: metadata,
                   path: FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
}

private func manualReleaseTarget(account: String? = "issuer:key") -> ASCReleaseOperationTarget {
    ASCReleaseOperationTarget(revision: UUID(), projectId: "project", appId: "app", bundleId: "org.example.MixedCase",
        accountKey: account, credentialRevision: 1, versionId: "version", platform: .iOS)
}

private func manualReleaseVersion(mode: String?) -> ASCAppStoreVersion {
    ASCAppStoreVersion(id: "version", attributes: .init(versionString: "1.2", appStoreState: "PREPARE_FOR_SUBMISSION",
        releaseType: mode, createdDate: nil, copyright: nil, platform: "IOS"))
}

private func manualReleaseBuild(app: String = "app", version: String = "1.2", platform: String = "IOS") -> ASCBuild {
    var build = ASCBuild(id: "build", attributes: .init(version: "12", uploadedDate: nil,
        processingState: "VALID", expirationDate: nil, expired: false, minOsVersion: nil, iconAssetToken: nil))
    build.relationships = .init(app: .init(data: .init(id: app)), preReleaseVersion: .init(data: .init(id: "prerelease")))
    build.preReleaseVersion = .init(id: "prerelease", attributes: .init(version: version, platform: platform))
    return build
}

@Test func manualSubmissionPreservesConfiguredReleaseModeAndExactIdentity() throws {
    for mode in ["MANUAL", "AFTER_APPROVAL"] {
        let request = try ASCManualReleaseRequest(project: manualReleaseProject(), captured: manualReleaseTarget(),
            version: manualReleaseVersion(mode: mode), build: manualReleaseBuild())
        #expect(request.mode.rawValue == mode)
        #expect(request.target.projectID == "project")
        #expect(request.target.appID == "app")
        #expect(request.target.bundleID == "org.example.MixedCase")
        #expect(request.target.versionID == "version")
        #expect(request.target.buildID == "build")
        #expect(request.target.accountKey == "issuer:key")
        #expect(request.target.platform == "IOS")
    }
}

@Test func manualSubmissionDoesNotCoerceMissingOrScheduledReleaseMode() {
    for mode in [nil, "", "SCHEDULED", "UNKNOWN"] as [String?] {
        #expect(throws: Error.self) {
            try ASCManualReleaseRequest(project: manualReleaseProject(), captured: manualReleaseTarget(),
                version: manualReleaseVersion(mode: mode), build: manualReleaseBuild())
        }
    }
}

@Test func manualSubmissionRejectsDifferentRegistrationAndAccount() {
    for project in [manualReleaseProject(bundle: "org.example.mixedcase"), manualReleaseProject(platform: .macOS)] {
        #expect(throws: Error.self) {
            try ASCManualReleaseRequest(project: project, captured: manualReleaseTarget(),
                version: manualReleaseVersion(mode: "MANUAL"), build: manualReleaseBuild())
        }
    }
    #expect(throws: Error.self) {
        try ASCManualReleaseRequest(project: manualReleaseProject(), captured: manualReleaseTarget(account: nil),
            version: manualReleaseVersion(mode: "MANUAL"), build: manualReleaseBuild())
    }
}

@Test func manualSubmissionRequiresBuildFromTheExactAppVersionAndPlatform() {
    for build in [manualReleaseBuild(app: "other"), manualReleaseBuild(version: "2.0"), manualReleaseBuild(platform: "MAC_OS")] {
        #expect(throws: Error.self) {
            try ASCManualReleaseRequest(project: manualReleaseProject(), captured: manualReleaseTarget(),
                version: manualReleaseVersion(mode: "MANUAL"), build: build)
        }
    }
}

@MainActor private final class ManualModeChangeService: ASCReleaseSubmissionService {
    var calls: [String] = []
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] {
        calls.append("versions")
        return [manualReleaseVersion(mode: "AFTER_APPROVAL")]
    }
    func fetchBuild(id: String) async throws -> ASCBuild { calls.append("build"); return manualReleaseBuild() }
    func fetchBuildAttachedToVersion(versionId: String) async throws -> ASCBuild? { calls.append("attached"); return manualReleaseBuild() }
    func attachBuild(versionId: String, buildId: String) async throws { calls.append("attach") }
    func submitForReview(appId: String, versionId: String) async throws { calls.append("submit") }
}

@MainActor @Test func manualSubmissionStopsBeforeAttachmentWhenPreviewReleaseModeChanged() async {
    let manager = ASCManager()
    manager.app = ASCApp(id: "app", attributes: .init(bundleId: "org.example.MixedCase", name: "App",
        primaryLocale: nil, vendorNumber: nil, contentRightsDeclaration: nil), relationships: nil)
    manager.loadedProjectId = "project"
    manager.releasePlatform = .iOS
    manager.appStoreVersions = [manualReleaseVersion(mode: "MANUAL")]
    manager.selectedVersionId = "version"
    let service = ManualModeChangeService()
    #expect(await manager.submitForReview(attachBuildId: "build", expectedReleaseMode: "MANUAL", using: service) == false)
    #expect(service.calls == ["versions"])
    #expect(manager.submissionError?.contains("Veröffentlichungsart") == true)
    #expect(!manager.isSubmitting)
}
