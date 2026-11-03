import Foundation
import Testing
@testable import Blitz

private func integrityVersion(_ id: String = "live", number: String = "1.9", state: String = "READY_FOR_SALE", platform: String = "IOS", date: String = "2026-10-01T00:00:00Z") -> ASCAppStoreVersion {
    ASCAppStoreVersion(id: id, attributes: .init(versionString: number, appStoreState: state,
        releaseType: "MANUAL", createdDate: date, copyright: "Example", platform: platform))
}

private func integrityBuild(_ id: String = "build") -> ASCBuild {
    ASCBuild(id: id, attributes: .init(version: "10", uploadedDate: nil, processingState: "VALID",
        expirationDate: nil, expired: false, minOsVersion: nil, iconAssetToken: nil))
}

@MainActor private func integrityManager(draft: Bool = false) -> ASCManager {
    let manager = ASCManager()
    manager.app = ASCApp(id: "app", attributes: .init(bundleId: "org.example.App", name: "App",
        primaryLocale: "de-DE", vendorNumber: nil, contentRightsDeclaration: nil), relationships: nil)
    manager.loadedProjectId = "project"
    manager.releasePlatform = .iOS
    manager.appStoreVersions = [integrityVersion()]
    if draft { manager.appStoreVersions.insert(integrityVersion("draft", number: "1.10", state: "PREPARE_FOR_SUBMISSION", date: "2026-10-02T00:00:00Z"), at: 0) }
    manager.selectedVersionId = draft ? "draft" : "live"
    return manager
}

@MainActor private final class IntegrityCreationService: ASCVersionCreationService {
    var versions = [integrityVersion()]
    var calls: [String] = []
    var copyConflict = false
    var patchFails = false
    var reviewError: Error? = ASCError.httpError(404, "Missing review")
    var onFetch: (() -> Void)?
    var patchedFields: [String: String]?
    var createdCopyright: String?
    private var copiedLocalization: ASCVersionLocalization {
        ASCVersionLocalization(id: "source-locale", attributes: .init(locale: "de-DE", title: nil,
            subtitle: nil, description: "Copied description", keywords: "keywords", promotionalText: nil,
            marketingUrl: nil, supportUrl: "https://example.com", whatsNew: "Previous release notes"))
    }
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] {
        calls.append("versions")
        onFetch?()
        return versions
    }
    func fetchLocalizations(versionId: String) async throws -> [ASCVersionLocalization] {
        calls.append("localizations:\(versionId)")
        if versionId == "created" {
            return [ASCVersionLocalization(id: "destination-locale", attributes: copiedLocalization.attributes)]
        }
        return [copiedLocalization]
    }
    func fetchReviewDetail(versionId: String) async throws -> ASCReviewDetail {
        calls.append("review")
        if let reviewError { throw reviewError }
        return ASCReviewDetail(id: "review", attributes: .init(contactFirstName: "Test"))
    }
    func createAppStoreVersion(appId: String, versionString: String, platform: String, copyright: String?, releaseType: String?) async throws -> ASCAppStoreVersion {
        calls.append("create")
        createdCopyright = copyright
        let created = integrityVersion("created", number: versionString, state: "PREPARE_FOR_SUBMISSION", platform: platform, date: "2026-10-03T00:00:00Z")
        versions.insert(created, at: 0)
        return created
    }
    func createVersionLocalization(versionId: String, locale: String, fields: [String: String]) async throws -> ASCVersionLocalization {
        calls.append("copy")
        if copyConflict { throw ASCError.httpError(409, "Locale exists") }
        return copiedLocalization
    }
    func patchLocalization(id: String, fields: [String: String]) async throws {
        calls.append("patch:\(id)")
        if patchFails { throw URLError(.notConnectedToInternet) }
        patchedFields = fields
    }
    func createOrPatchReviewDetail(versionId: String, attributes: [String: Any]) async throws -> ASCReviewDetail {
        calls.append("copy-review")
        return ASCReviewDetail(id: "review", attributes: .init())
    }
    func attachBuild(versionId: String, buildId: String) async throws { calls.append("attach") }
}

@Test func releasePlatformFilteringDoesNotAdoptAnotherPlatformsDraftOrUnknownIdentity() {
    let versions = [integrityVersion(), integrityVersion("mac", number: "2.0", state: "PREPARE_FOR_SUBMISSION", platform: "MAC_OS")]
    #expect(ASCReleaseStatus.versions(versions, for: .iOS).map(\.id) == ["live"])
    #expect(ASCReleaseStatus.versions(versions, for: .macOS).map(\.id) == ["mac"])
    var unknown = integrityVersion("unknown")
    unknown = ASCAppStoreVersion(id: unknown.id, attributes: .init(versionString: "2.0", appStoreState: "PREPARE_FOR_SUBMISSION", releaseType: nil, createdDate: nil, copyright: nil))
    #expect(ASCReleaseStatus.versions([unknown], for: .iOS).isEmpty)
}

@Test func dashboardPreservesReviewStatusAcrossPlatforms() {
    let state = ASCDashboardProjectStatus(versions: [
        integrityVersion("ios", date: "2026-10-03T00:00:00Z"),
        integrityVersion("mac", number: "1.0", state: "WAITING_FOR_REVIEW", platform: "MAC_OS", date: "2026-10-02T00:00:00Z")
    ])
    #expect(state.isLiveOnStore)
    #expect(state.isPendingReview)
}

@Test func newReleaseVersionMustBeNumericAndHigherThanEntirePlatformHistory() {
    let history = [integrityVersion()]
    for value in ["", "1..2", "1.2-beta", "1.2.3.4", "1.8", "1.9", "1.9.0", "01.09", "999999999999999999999999"] {
        #expect(ASCReleaseStatus.newVersionError(value, history: history) != nil)
    }
    #expect(ASCReleaseStatus.newVersionError("1.10", history: history) == nil)
    #expect(ASCReleaseStatus.newVersionError(" 2.0 ", history: history) == nil)
}

@MainActor @Test func explicitNoCopySourceDoesNotFallBackToLiveMetadata() async {
    let manager = integrityManager(), service = IntegrityCreationService()
    let result = await manager.createUpdateVersion(versionString: "1.10", platform: .iOS, copyFromVersionId: "", using: service)
    #expect(result?.id == "created")
    #expect(service.calls == ["versions", "create", "versions"])
    #expect(service.createdCopyright == nil)
    #expect(manager.versionCreationError == nil)
}

@MainActor @Test func draftRejectsInvalidSourceAndReviewReadFailureBeforeCreation() async {
    let manager = integrityManager(), service = IntegrityCreationService()
    #expect(await manager.createUpdateVersion(versionString: "1.10", platform: .iOS, copyFromVersionId: "other-platform", using: service) == nil)
    #expect(service.calls == ["versions"])
    #expect(manager.versionCreationError != nil)
    let retryManager = integrityManager(), retryService = IntegrityCreationService()
    retryService.reviewError = URLError(.notConnectedToInternet)
    #expect(await retryManager.createUpdateVersion(versionString: "1.10", platform: .iOS, using: retryService) == nil)
    #expect(!retryService.calls.contains("create"))
    #expect(retryManager.versionCreationError != nil)
    #expect(!retryManager.isCreatingVersion)
}

@MainActor @Test func localizationConflictCopiesIntoExistingLocaleWithoutOldReleaseNotes() async {
    let manager = integrityManager(), service = IntegrityCreationService()
    service.copyConflict = true
    let result = await manager.createUpdateVersion(versionString: "1.10", platform: .iOS, copyReviewDetail: false, using: service)
    #expect(result?.id == "created")
    #expect(service.calls.contains("localizations:created"))
    #expect(service.calls.contains("patch:destination-locale"))
    #expect(service.patchedFields?["description"] == "Copied description")
    #expect(service.patchedFields?["whatsNew"] == nil)
    #expect(manager.versionCreationError == nil)
}

@MainActor @Test func failedCopyKeepsCreatedDraftAndReportsPartialResult() async {
    let manager = integrityManager(), service = IntegrityCreationService()
    service.copyConflict = true
    service.patchFails = true
    let result = await manager.createUpdateVersion(versionString: "1.10", platform: .iOS, copyReviewDetail: false, using: service)
    #expect(result == nil)
    #expect(service.calls.filter { $0 == "create" }.count == 1)
    #expect(manager.appStoreVersions.contains { $0.id == "created" })
    #expect(manager.versionCreationError?.contains("nicht vollständig vorbereitet") == true)
    #expect(!manager.isCreatingVersion)
}

@MainActor @Test func releaseTargetRejectsVersionPlatformAndRevisionChanges() throws {
    let manager = integrityManager(draft: true)
    let target = try #require(manager.releaseOperationTarget())
    #expect(target.matches(manager))
    manager.selectedVersionId = "live"
    #expect(!target.matches(manager))
    manager.selectedVersionId = "draft"
    manager.releasePlatform = .macOS
    #expect(!target.matches(manager))
    manager.releasePlatform = .iOS
    manager.projectRevision = UUID()
    #expect(!target.matches(manager))
}

@MainActor private final class IntegrityBuildService: ASCVersionBuildService {
    let onRead: () -> Void
    init(onRead: @escaping () -> Void) { self.onRead = onRead }
    func fetchBuildAttachedToVersion(versionId: String) async throws -> ASCBuild? {
        onRead()
        return integrityBuild("stale")
    }
}

@MainActor @Test func delayedAttachedBuildCannotOverwriteNewVersionSelection() async {
    let manager = integrityManager(draft: true)
    let service = IntegrityBuildService {
        manager.prepareForVersionSelection("live")
        manager.selectedVersionBuild = integrityBuild("current")
    }
    await manager.refreshSelectedVersionBuild(using: service)
    #expect(manager.selectedVersionId == "live")
    #expect(manager.selectedVersionBuild?.id == "current")
}

@MainActor private final class IntegritySubmissionService: ASCReleaseSubmissionService {
    var calls: [String] = []
    let onRead: () -> Void
    var onBuildRead: (() -> Void)?
    var candidateBuild = integrityMatchedBuild()
    init(onRead: @escaping () -> Void = {}) { self.onRead = onRead }
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] {
        calls.append("versions")
        onRead()
        return [integrityVersion("draft", number: "1.10", state: "PREPARE_FOR_SUBMISSION"), integrityVersion()]
    }
    func fetchBuild(id: String) async throws -> ASCBuild {
        calls.append("build")
        onBuildRead?()
        return candidateBuild
    }
    func fetchBuildAttachedToVersion(versionId: String) async throws -> ASCBuild? { calls.append("attached"); return integrityBuild() }
    func attachBuild(versionId: String, buildId: String) async throws { calls.append("attach") }
    func submitForReview(appId: String, versionId: String) async throws { calls.append("submit") }
}

@MainActor @Test func cancelledSubmissionAfterVersionSwitchClearsBusyStateAndNeverWrites() async {
    let manager = integrityManager(draft: true)
    let service = IntegritySubmissionService { manager.prepareForVersionSelection("live") }
    #expect(await manager.submitForReview(using: service) == false)
    #expect(service.calls == ["versions"])
    #expect(!manager.isSubmitting)
}

private func integrityMatchedBuild(app: String = "app", marketing: String = "1.10", platform: String = "IOS", state: String = "VALID", expired: Bool = false) -> ASCBuild {
    var build = ASCBuild(id: "build", attributes: .init(version: "10", uploadedDate: nil,
        processingState: state, expirationDate: nil, expired: expired, minOsVersion: nil, iconAssetToken: nil))
    build.relationships = .init(app: .init(data: .init(id: app)), preReleaseVersion: .init(data: .init(id: "prerelease")))
    build.preReleaseVersion = .init(id: "prerelease", attributes: .init(version: marketing, platform: platform))
    return build
}

@MainActor @Test func submissionRejectsWrongAppVersionPlatformAndUnusableBuildBeforeAttachment() async {
    for build in [integrityMatchedBuild(app: "other-app"), integrityMatchedBuild(marketing: "2.0"),
                  integrityMatchedBuild(platform: "MAC_OS"), integrityMatchedBuild(state: "PROCESSING"),
                  integrityMatchedBuild(expired: true), integrityBuild("missing-identity")] {
        let manager = integrityManager(draft: true), service = IntegritySubmissionService()
        service.candidateBuild = build
        #expect(await manager.submitForReview(attachBuildId: build.id, using: service) == false)
        #expect(service.calls == ["versions", "build"])
        #expect(manager.submissionError != nil)
        #expect(!manager.isSubmitting)
    }
}

@MainActor @Test func submissionRechecksAppAndAccountAfterFetchingSelectedBuild() async {
    for changeAccount in [false, true] {
        let manager = integrityManager(draft: true), service = IntegritySubmissionService()
        service.onBuildRead = {
            if changeAccount {
                manager.credentials = ASCCredentials(issuerId: "fixture-issuer", keyId: "fixture-key", privateKey: "unused-fixture")
            } else if let original = manager.app {
                manager.app = ASCApp(id: "other-app", attributes: original.attributes, relationships: nil)
            }
        }
        #expect(await manager.submitForReview(attachBuildId: "build", using: service) == false)
        #expect(service.calls == ["versions", "build"])
        #expect(!manager.isSubmitting)
    }
}

@MainActor @Test func submissionAttachesOnlyTheExplicitMatchingBuildAfterValidation() async {
    let manager = integrityManager(draft: true), service = IntegritySubmissionService()
    #expect(await manager.submitForReview(attachBuildId: "build", using: service))
    #expect(service.calls == ["versions", "build", "attach", "submit"])
    #expect(manager.selectedVersionBuild?.id == "build")
    #expect(!manager.isSubmitting)
}
