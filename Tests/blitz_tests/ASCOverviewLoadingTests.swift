import Foundation
import Testing
@testable import Blitz

private func decoded<T: Decodable>(_ text: String, as: T.Type = T.self) -> T {
    try! JSONDecoder().decode(T.self, from: Data(text.utf8))
}

private let listingApp: ASCApp = decoded(#"{"id":"app-a","attributes":{"name":"Example","bundleId":"org.example.a","primaryLocale":"de-DE"}}"#)
private let listingVersion: ASCAppStoreVersion = decoded(#"{"id":"version-a","attributes":{"versionString":"1.2","appStoreState":"READY_FOR_SALE"}}"#)
private let listingText: ASCVersionLocalization = decoded(#"{"id":"locale-a","attributes":{"locale":"de-DE","description":"Saved description","keywords":"words","supportUrl":"https://example.org"}}"#)

private actor OverviewGate {
    private var entered = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        arrival?.resume(); arrival = nil
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { arrival = $0 } }
    }
    func release() {
        released = true
        waiter?.resume(); waiter = nil
    }
}

private struct OverviewFixtureService: ASCOverviewService {
    var screenshotsGate: OverviewGate?
    var failLocalizations = false
    var failPrivacy = false
    func fetchApp(id: String) async throws -> ASCApp { listingApp }
    func fetchBuilds(appId: String) async throws -> [ASCBuild] { [] }
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] { [listingVersion] }
    func fetchLocalizations(versionId: String) async throws -> [ASCVersionLocalization] {
        if failLocalizations { throw URLError(.timedOut) }
        return [listingText]
    }
    func fetchAppInfo(appId: String) async throws -> ASCAppInfo {
        decoded(#"{"id":"info-a","attributes":{},"relationships":{"primaryCategory":{"data":{"id":"EDUCATION"}}}}"#)
    }
    func fetchAppInfoLocalizations(appInfoId: String) async throws -> [ASCAppInfoLocalization] {
        if failPrivacy { throw URLError(.notConnectedToInternet) }
        return [decoded(#"{"id":"info-locale","attributes":{"locale":"de-DE","name":"Example","privacyPolicyUrl":"https://example.org/privacy"}}"#)]
    }
    func fetchAgeRating(appInfoId: String) async throws -> ASCAgeRatingDeclaration {
        decoded(#"{"id":"age","attributes":{}}"#)
    }
    func fetchReviewDetail(versionId: String) async throws -> ASCReviewDetail {
        throw ASCError.notFound("No review detail")
    }
    func fetchBuildAttachedToVersion(versionId: String) async throws -> ASCBuild? { nil }
    func fetchScreenshotSets(localizationId: String) async throws -> [ASCScreenshotSet] {
        await screenshotsGate?.wait()
        return []
    }
    func fetchScreenshots(setId: String) async throws -> [ASCScreenshot] { [] }
    func fetchPricingConfiguredDetailed(appId: String) async throws -> Bool { true }
}

@MainActor
private func overviewManager() -> ASCManager {
    let manager = ASCManager()
    manager.loadedProjectId = "asc:org.example.a"
    manager.app = listingApp
    return manager
}

@MainActor
@Test func overviewPublishesTextBeforeSlowScreenshotsAndKeepsUIExecutorAvailable() async {
    let manager = overviewManager()
    let gate = OverviewGate()
    let task = Task { await manager.loadOverview(using: OverviewFixtureService(screenshotsGate: gate)) }
    await gate.waitUntilEntered()
    #expect(manager.localizations.first?.attributes.description == "Saved description")
    #expect(!manager.overviewReadinessLoadingFields.contains("Description"))
    #expect(manager.overviewReadinessLoadingFields.contains("iPhone Screenshots"))
    // This assertion runs on the UI actor while the network request is suspended.
    #expect(manager.overviewFailedFields.isEmpty)
    await gate.release()
    await task.value
}

@MainActor
@Test func overviewFailureRetainsSavedTextAndIsNotAMissingRequiredField() async {
    let manager = overviewManager()
    manager.localizations = [listingText]
    manager.selectedVersionId = listingVersion.id
    await manager.loadOverview(using: OverviewFixtureService(failLocalizations: true, failPrivacy: true))
    #expect(manager.localizations.first?.attributes.description == "Saved description")
    let fields = manager.submissionReadiness.fields
    #expect(fields.first { $0.label == "Description" }?.loadFailed == true)
    #expect(fields.first { $0.label == "Privacy Policy URL" }?.loadFailed == true)
    #expect(fields.first { $0.label == "App Name" }?.loadFailed == true)
    #expect(!manager.submissionReadiness.missingRequired.contains { $0.label == "Privacy Policy URL" })
    #expect(!manager.submissionReadiness.isComplete)
    #expect(manager.monetizationStatus == "Configured")
}

@MainActor
@Test func overviewRetryReplacesFailureWithConfirmedEmptyOrSuccess() async {
    let manager = overviewManager()
    await manager.loadOverview(using: OverviewFixtureService(failPrivacy: true))
    #expect(manager.overviewFailedFields.contains("Privacy Policy URL"))
    await manager.loadOverview(using: OverviewFixtureService())
    #expect(manager.overviewFailedFields.isEmpty)
    #expect(manager.primaryAppInfoLocalization()?.attributes.privacyPolicyUrl == "https://example.org/privacy")
    #expect(manager.submissionReadiness.missingRequired.contains { $0.label == "Review Contact Email" })
}

@MainActor
@Test func overviewLateResponsesCannotOverwriteAnotherProjectOrSameProjectReopened() async {
    let manager = overviewManager()
    let gate = OverviewGate()
    let task = Task { await manager.loadOverview(using: OverviewFixtureService(screenshotsGate: gate)) }
    await gate.waitUntilEntered()
    manager.resetProjectData(preserveCredentials: true)
    // Even A -> B -> A must reject the old request, rather than compare only IDs.
    manager.loadedProjectId = "asc:org.example.a"
    manager.app = listingApp
    manager.overviewFailedFields = ["new-state"]
    await gate.release()
    await task.value
    #expect(manager.localizations.isEmpty)
    #expect(manager.overviewFailedFields == ["new-state"])
    #expect(manager.overviewCacheDate == nil)
    #expect(manager.screenshotSetsByLocale.isEmpty)
}

@MainActor
@Test func overviewSnapshotFromPartialRefreshMustRevalidate() {
    let manager = overviewManager()
    manager.loadedTabs = [.app]
    manager.tabLoadedAt[.app] = Date()
    manager.overviewReadinessLoadingFields = ["Age Rating"]
    let snapshot = ASCManager.ProjectSnapshot(manager: manager, projectId: "example")
    #expect(!snapshot.loadedTabs.contains(.app))
}

@MainActor
@Test func overviewVersionSwitchDiscardsOldVersionResponse() async {
    let manager = overviewManager()
    let gate = OverviewGate()
    let task = Task { await manager.loadOverview(using: OverviewFixtureService(screenshotsGate: gate)) }
    await gate.waitUntilEntered()
    manager.prepareForVersionSelection("next-version")
    await gate.release()
    await task.value
    #expect(manager.selectedVersionId == "next-version")
    #expect(manager.localizations.isEmpty)
    #expect(manager.screenshotSetsByLocale.isEmpty)
    #expect(manager.overviewCacheDate == nil)
}

@MainActor
@Test func overviewSnapshotsNeverCrossAccounts() {
    let manager = overviewManager()
    manager.credentials = ASCCredentials(issuerId: "first", keyId: "key", privateKey: "unused")
    manager.projectSnapshots["second-project"] = ASCManager.ProjectSnapshot(manager: manager, projectId: "second-project")
    manager.credentials = ASCCredentials(issuerId: "second", keyId: "key", privateKey: "unused")
    manager.prepareForProjectSwitch(to: "second-project", bundleId: listingApp.bundleId)
    #expect(manager.app == nil)
}

@MainActor
@Test func overviewDiskCacheIsScopedExpiresAndExcludesSecrets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ASCOverviewCache(directory: root)
    let manager = overviewManager()
    manager.selectedVersionId = listingVersion.id
    manager.appStoreVersions = [listingVersion]
    manager.localizations = [listingText]
    manager.credentials = ASCCredentials(issuerId: "issuer", keyId: "key", privateKey: "PRIVATE-KEY-SENTINEL")
    manager.reviewDetail = decoded(#"{"id":"review","attributes":{"contactEmail":"PRIVATE-CONTACT-SENTINEL","demoAccountName":"PRIVATE-LOGIN-SENTINEL","demoAccountPassword":"PRIVATE-PASSWORD-SENTINEL"}}"#)
    manager.overviewResolvedFields = ASCManager.overviewAllFields
    let date = Date()
    await cache.save(ASCOverviewCacheEntry(manager: manager, savedAt: date), account: "account-a")
    let loaded = await cache.load(account: "account-a", bundle: listingApp.bundleId)
    #expect(loaded?.localizations.first?.attributes.description == "Saved description")
    #expect(await cache.load(account: "account-b", bundle: listingApp.bundleId) == nil)
    #expect(await cache.load(account: "account-a", bundle: "wrong.bundle") == nil)
    #expect(await cache.load(account: "account-a", bundle: listingApp.bundleId,
                             now: date.addingTimeInterval(ASCOverviewCache.maximumAge + 1)) == nil)
    let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
    let bytes = try String(contentsOf: file, encoding: .utf8)
    #expect(!bytes.contains("SENTINEL"))
    #expect(!bytes.contains("reviewDetail"))
    let restored = ASCManager()
    loaded?.apply(to: restored)
    #expect(restored.localizations.count == 1)
    #expect(restored.reviewDetail == nil)
    #expect(restored.shouldRefreshTabCache(.app))
    #expect(restored.overviewReadinessLoadingFields.contains("Review Contact Email"))
    try Data("broken cache".utf8).write(to: file)
    #expect(await cache.load(account: "account-a", bundle: listingApp.bundleId) == nil)
}

@MainActor
@Test func overviewDiskCacheEvictsBeyondItsLimit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ASCOverviewCache(directory: root)
    let entry = ASCOverviewCacheEntry(manager: overviewManager())
    for index in 0..<(ASCOverviewCache.maximumEntries + 3) {
        await cache.save(entry, account: "account-\(index)")
    }
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    #expect(files.count == ASCOverviewCache.maximumEntries)
}
