import Foundation
import Testing
@testable import Blitz

private func reviewFixture<T: Decodable>(_ json: String) -> T {
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private let reviewApp: ASCApp = reviewFixture(#"{"id":"app-a","attributes":{"name":"A","bundleId":"org.example.a"}}"#)
private let reviewVersion: ASCAppStoreVersion = reviewFixture(#"{"id":"version-a","attributes":{"versionString":"1.0","appStoreState":"READY_FOR_SALE","platform":"IOS","createdDate":"2026-01-01T00:00:00Z"}}"#)
private let nextReviewVersion: ASCAppStoreVersion = reviewFixture(#"{"id":"version-next","attributes":{"versionString":"2.0","appStoreState":"PREPARE_FOR_SUBMISSION","platform":"IOS","createdDate":"2026-02-01T00:00:00Z"}}"#)

/// Intentionally ignores cancellation, like a response already in flight.
private actor ReviewResponseGate {
    private var entered = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        arrival?.resume(); arrival = nil
        if !released { await withCheckedContinuation { response = $0 } }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { arrival = $0 } }
    }

    func release() {
        released = true
        response?.resume(); response = nil
    }
}

private enum ReviewResponseStep { case versions, detail, builds, ageRating, submissionItems }

private struct ReviewDataFixtureService: ASCReviewDataService {
    let step: ReviewResponseStep
    let gate: ReviewResponseGate

    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] {
        if step == .versions { await gate.wait() }
        return [nextReviewVersion, reviewVersion]
    }
    func fetchAppInfo(appId: String) async throws -> ASCAppInfo {
        reviewFixture(#"{"id":"info-a","attributes":{}}"#)
    }
    func fetchBuilds(appId: String) async throws -> [ASCBuild] {
        if step == .builds { await gate.wait() }
        return [reviewFixture(#"{"id":"build-a","attributes":{"version":"10"}}"#)]
    }
    func fetchReviewDetail(versionId: String) async throws -> ASCReviewDetail {
        if step == .detail { await gate.wait() }
        return reviewFixture("{\"id\":\"detail-\(versionId)\",\"attributes\":{\"contactEmail\":\"old@example.org\"}}")
    }
    func fetchBuildAttachedToVersion(versionId: String) async throws -> ASCBuild? {
        reviewFixture("{\"id\":\"build-\(versionId)\",\"attributes\":{\"version\":\"10\"}}")
    }
    func fetchAgeRating(appInfoId: String) async throws -> ASCAgeRatingDeclaration {
        if step == .ageRating { await gate.wait() }
        return reviewFixture(#"{"id":"age-a","attributes":{}}"#)
    }
    func fetchReviewSubmissions(appId: String) async throws -> [ASCReviewSubmission] {
        [reviewFixture(#"{"id":"submission-a","attributes":{"state":"ACCEPTED","submittedDate":"2026-02-01T00:00:00Z"}}"#)]
    }
    func fetchReviewSubmissionItems(submissionId: String) async throws -> [ASCReviewSubmissionItem] {
        if step == .submissionItems { await gate.wait() }
        return []
    }
}

@MainActor
private func reviewDataManager() -> ASCManager {
    let manager = ASCManager()
    manager.loadedProjectId = "project-a"
    manager.app = reviewApp
    manager.credentials = ASCCredentials(issuerId: "issuer-a", keyId: "key-a", privateKey: "unused")
    manager.releasePlatform = .iOS
    manager.appStoreVersions = [reviewVersion]
    manager.selectedVersionId = reviewVersion.id
    return manager
}

@MainActor
private func markCurrentReviewData(_ manager: ASCManager) {
    manager.reviewDetail = reviewFixture(#"{"id":"current-detail","attributes":{"contactEmail":"current@example.org"}}"#)
    manager.selectedVersionBuild = reviewFixture(#"{"id":"current-build","attributes":{"version":"20"}}"#)
    manager.appInfo = reviewFixture(#"{"id":"current-info","attributes":{}}"#)
    manager.builds = [reviewFixture(#"{"id":"current-history-build","attributes":{"version":"20"}}"#)]
    manager.ageRatingDeclaration = reviewFixture(#"{"id":"current-age","attributes":{}}"#)
    manager.reviewSubmissions = [reviewFixture(#"{"id":"current-submission","attributes":{"submittedDate":"2026-03-01T00:00:00Z"}}"#)]
}

@MainActor
private func expectCurrentReviewData(_ manager: ASCManager) {
    #expect(manager.reviewDetail?.id == "current-detail")
    #expect(manager.selectedVersionBuild?.id == "current-build")
    #expect(manager.appInfo?.id == "current-info")
    #expect(manager.builds.map(\.id) == ["current-history-build"])
    #expect(manager.ageRatingDeclaration?.id == "current-age")
    #expect(manager.reviewSubmissions.map(\.id) == ["current-submission"])
}

@MainActor
@Test func reviewCancelledProjectLoadCannotOverwriteTheNewProject() async {
    let manager = reviewDataManager()
    let gate = ReviewResponseGate()
    let task = Task { try? await manager.loadReviewTab(using: ReviewDataFixtureService(step: .builds, gate: gate)) }
    await gate.waitUntilEntered()
    task.cancel()
    manager.resetProjectData(preserveCredentials: true)
    manager.loadedProjectId = "project-b"
    manager.app = reviewFixture(#"{"id":"app-b","attributes":{"name":"B","bundleId":"org.example.b"}}"#)
    manager.appStoreVersions = [nextReviewVersion]
    manager.selectedVersionId = nextReviewVersion.id
    markCurrentReviewData(manager)
    await gate.release()
    await task.value

    expectCurrentReviewData(manager)
    #expect(manager.appStoreVersions.map(\.id) == [nextReviewVersion.id])
    #expect(manager.selectedVersionId == nextReviewVersion.id)
    #expect(manager.tabHydrationTasks[.review] == nil)
}

@MainActor
@Test(arguments: [false, true])
func reviewVersionSwitchRejectsThePreviousVersionsContactAndBuild(directSelection: Bool) async {
    let manager = reviewDataManager()
    let gate = ReviewResponseGate()
    let task = Task { try? await manager.loadReviewTab(using: ReviewDataFixtureService(step: .detail, gate: gate)) }
    await gate.waitUntilEntered()
    #expect(manager.appStoreVersions.map(\.id) == [reviewVersion.id])
    manager.appStoreVersions = [nextReviewVersion, reviewVersion]
    if directSelection {
        manager.selectedVersionId = nextReviewVersion.id
    } else {
        manager.prepareForVersionSelection(nextReviewVersion.id)
    }
    markCurrentReviewData(manager)
    await gate.release()
    await task.value

    expectCurrentReviewData(manager)
    #expect(manager.selectedVersionId == nextReviewVersion.id)
    #expect(manager.tabHydrationTasks[.review] == nil)
}

@MainActor
@Test(arguments: [false, true])
func reviewAccountReactivationOrChangeRejectsPendingVersions(sameAccount: Bool) async {
    let manager = reviewDataManager()
    let gate = ReviewResponseGate()
    let task = Task { try? await manager.loadReviewTab(using: ReviewDataFixtureService(step: .versions, gate: gate)) }
    await gate.waitUntilEntered()
    if sameAccount {
        manager.credentialActivationRevision += 1
    } else {
        manager.credentials = ASCCredentials(issuerId: "issuer-b", keyId: "key-b", privateKey: "unused")
    }
    markCurrentReviewData(manager)
    await gate.release()
    await task.value

    expectCurrentReviewData(manager)
    #expect(manager.appStoreVersions.map(\.id) == [reviewVersion.id])
    #expect(manager.tabHydrationTasks[.review] == nil)
}

@MainActor
@Test func reviewCredentialResetCannotReviveAPendingLoadForTheSameApp() async {
    let manager = reviewDataManager()
    let gate = ReviewResponseGate()
    let task = Task { try? await manager.loadReviewTab(using: ReviewDataFixtureService(step: .builds, gate: gate)) }
    await gate.waitUntilEntered()
    manager.resetProjectData(preserveCredentials: false)
    manager.loadedProjectId = "project-a"
    manager.app = reviewApp
    manager.credentials = ASCCredentials(issuerId: "issuer-a", keyId: "key-a", privateKey: "unused")
    manager.appStoreVersions = [reviewVersion]
    manager.selectedVersionId = reviewVersion.id
    markCurrentReviewData(manager)
    await gate.release()
    await task.value

    expectCurrentReviewData(manager)
    #expect(manager.appStoreVersions.map(\.id) == [reviewVersion.id])
    #expect(manager.tabHydrationTasks[.review] == nil)
}

@MainActor
@Test func reviewInitialLoadSelectsTheDefaultVersionAndPublishesMatchingDetailsTogether() async throws {
    let manager = reviewDataManager()
    manager.appStoreVersions = []
    manager.selectedVersionId = nil
    let gate = ReviewResponseGate()
    try await manager.loadReviewTab(using: ReviewDataFixtureService(step: .ageRating, gate: gate))
    await gate.waitUntilEntered()
    let secondary = manager.tabHydrationTasks[.review]
    manager.cancelBackgroundHydration(for: .review)
    await gate.release()
    await secondary?.value

    #expect(manager.selectedVersionId == nextReviewVersion.id)
    #expect(manager.reviewDetail?.id == "detail-version-next")
    #expect(manager.selectedVersionBuild?.id == "build-version-next")
    #expect(manager.appInfo?.id == "info-a")
    #expect(manager.builds.map(\.id) == ["build-a"])
}

@MainActor
@Test func reviewSecondaryAgeRatingRejectsSameProjectReopened() async throws {
    let manager = reviewDataManager()
    let gate = ReviewResponseGate()
    try await manager.loadReviewTab(using: ReviewDataFixtureService(step: .ageRating, gate: gate))
    await gate.waitUntilEntered()
    let secondary = manager.tabHydrationTasks[.review]
    manager.resetProjectData(preserveCredentials: true)
    manager.loadedProjectId = "project-a"
    manager.app = reviewApp
    manager.appStoreVersions = [reviewVersion]
    manager.selectedVersionId = reviewVersion.id
    markCurrentReviewData(manager)
    await gate.release()
    await secondary?.value

    expectCurrentReviewData(manager)
}

@MainActor
@Test func reviewSecondarySubmissionHistoryDoesNotCommitAfterVersionChange() async throws {
    let manager = reviewDataManager()
    let gate = ReviewResponseGate()
    try await manager.loadReviewTab(using: ReviewDataFixtureService(step: .submissionItems, gate: gate))
    await gate.waitUntilEntered()
    // History must remain a single snapshot while its items are outstanding.
    #expect(manager.reviewSubmissions.isEmpty)
    let secondary = manager.tabHydrationTasks[.review]
    manager.prepareForVersionSelection(nextReviewVersion.id)
    markCurrentReviewData(manager)
    await gate.release()
    await secondary?.value

    expectCurrentReviewData(manager)
    #expect(manager.reviewSubmissionItemsBySubmissionId.isEmpty)
}
