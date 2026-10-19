import AppKit
import Foundation
import Testing
@testable import Blitz

private func decodeTab<T: Decodable>(_ json: String, as: T.Type = T.self) -> T {
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}
private let cacheApp: ASCApp = decodeTab(#"{"id":"app-a","attributes":{"name":"Example","bundleId":"org.example.cache","primaryLocale":"de-DE"}}"#)
private let cacheVersion: ASCAppStoreVersion = decodeTab(#"{"id":"version-a","attributes":{"versionString":"1.0","appStoreState":"PREPARE_FOR_SUBMISSION"}}"#)
private let cacheText: ASCVersionLocalization = decodeTab(#"{"id":"loc-a","attributes":{"locale":"de-DE","description":"Saved text"}}"#)
private let cacheBuild: ASCBuild = decodeTab(#"{"id":"build-a","attributes":{"version":"12"}}"#)
private let pixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jY1sAAAAASUVORK5CYII=")!

@MainActor private func tabManager() -> ASCManager {
    let manager = ASCManager()
    manager.app = cacheApp
    manager.appStoreVersions = [cacheVersion]
    manager.selectedVersionId = cacheVersion.id
    manager.localizations = [cacheText]
    manager.loadedProjectId = "example"
    return manager
}
private func temporaryCache() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

@MainActor @Test func tabCacheScopesAccountAppVersionAndRejectsInvalidFiles() async throws {
    let root = temporaryCache()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ASCTabCache(directory: root)
    let manager = tabManager()
    let entry = try #require(ASCTabCacheEntry(manager: manager, tab: .appInformation))
    await cache.save(entry, account: "a")
    let restored = await cache.load(account: "a", appId: "app-a", tab: .appInformation, versionId: "version-a")
    #expect(restored?.localizations?.first?.attributes.description == "Saved text")
    #expect(await cache.load(account: "b", appId: "app-a", tab: .appInformation, versionId: "version-a") == nil)
    #expect(await cache.load(account: "a", appId: "other", tab: .appInformation, versionId: "version-a") == nil)
    #expect(await cache.load(account: "a", appId: "app-a", tab: .appInformation, versionId: "other") == nil)
    #expect(await cache.load(account: "a", appId: "app-a", tab: .appInformation, versionId: "version-a", now: entry.savedAt.addingTimeInterval(ASCTabCache.maximumAge + 1)) == nil)
    let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
    try Data(repeating: 0, count: ASCTabCache.maximumEntryBytes + 1).write(to: file)
    #expect(await cache.load(account: "a", appId: "app-a", tab: .appInformation, versionId: "version-a") == nil)
    try Data("broken".utf8).write(to: file)
    #expect(await cache.load(account: "a", appId: "app-a", tab: .appInformation, versionId: "version-a") == nil)
}

@MainActor @Test func tabCacheRestoresConfirmedEmptyDataButAlwaysRevalidates() throws {
    let manager = tabManager()
    let entry = try #require(ASCTabCacheEntry(manager: manager, tab: .groups))
    manager.betaGroups = [decodeTab(#"{"id":"old","attributes":{"name":"Old"}}"#)]
    #expect(entry.apply(to: manager, tab: .groups))
    #expect(manager.betaGroups.isEmpty)
    #expect(manager.hasLoadedTabData(.groups))
    #expect(manager.shouldRefreshTabCache(.groups))
    #expect(!entry.apply(to: manager, tab: .betaInfo))
}

@MainActor @Test func tabCacheCannotApplyAnotherVersionOrOverwriteScreenshotEdits() throws {
    let manager = tabManager()
    let screenshot: ASCScreenshot = decodeTab(#"{"id":"remote","attributes":{"fileName":"remote.png"}}"#)
    let set: ASCScreenshotSet = decodeTab(#"{"id":"set","attributes":{"screenshotDisplayType":"APP_IPHONE_67"}}"#)
    manager.updateScreenshotCache(locale: "de-DE", sets: [set], screenshots: ["set": [screenshot]])
    let entry = try #require(ASCTabCacheEntry(manager: manager, tab: .screenshots))
    let key = manager.screenshotTrackKey(displayType: "APP_IPHONE_67", locale: "de-DE")
    manager.trackSlots[key] = [TrackSlot(id: "local-draft", localPath: "/tmp/draft.png", localImage: nil, ascScreenshot: nil, isFromASC: false)] + Array(repeating: nil, count: 9)
    #expect(entry.apply(to: manager, tab: .screenshots))
    #expect(manager.trackSlots[key]?.first??.id == "local-draft")
    manager.appStoreVersions.append(decodeTab(#"{"id":"another-version","attributes":{"versionString":"2.0"}}"#))
    manager.prepareForVersionSelection("another-version")
    #expect(!entry.apply(to: manager, tab: .screenshots))
}

@MainActor @Test func tabCacheExcludesFeedbackCredentialsAndUnsavedTracks() throws {
    let manager = tabManager()
    manager.credentials = ASCCredentials(issuerId: "a", keyId: "key", privateKey: "SECRET-SENTINEL")
    manager.betaFeedback["build-a"] = [decodeTab(#"{"id":"feedback","attributes":{"comment":"PRIVATE-SENTINEL","email":"TESTER-SENTINEL"}}"#)]
    manager.pendingFormValues["appInformation"] = ["description": "DRAFT-SENTINEL"]
    manager.betaGroups = [decodeTab(#"{"id":"g","attributes":{"name":"Internal","isInternalGroup":true}}"#)]
    manager.betaLocalizations = [decodeTab(#"{"id":"b","attributes":{"locale":"de-DE","description":"Beta text"}}"#)]
    for tab in ASCTabCacheEntry.tabs {
        let entry = try #require(ASCTabCacheEntry(manager: manager, tab: tab))
        let json = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        #expect(!json.contains("SENTINEL"))
        #expect(!json.contains("trackSlots"))
    }
    #expect(ASCTabCacheEntry(manager: manager, tab: .feedback) == nil)
}

@MainActor @Test func overviewResourcesAreReusedByInformationAndBuildTabs() async {
    let manager = tabManager()
    manager.builds = [cacheBuild]
    await manager.shareOverviewDataWithTabs(includeBuilds: true)
    #expect(!manager.shouldRefreshTabCache(.appInformation))
    #expect(!manager.shouldRefreshTabCache(.builds))
    manager.resetProjectData(preserveCredentials: true)
    #expect(manager.tabLoadedAt.isEmpty)
}

private actor TabGate {
    var started = false
    var isReleased = false
    var arrival: CheckedContinuation<Void, Never>?
    var waits: [CheckedContinuation<Void, Never>] = []
    var calls = 0
    func wait() async {
        calls += 1
        started = true
        arrival?.resume(); arrival = nil
        if !isReleased { await withCheckedContinuation { waits.append($0) } }
    }
    func entered() async { if !started { await withCheckedContinuation { arrival = $0 } } }
    func release() { isReleased = true; waits.forEach { $0.resume() }; waits = [] }
}
private struct FlightFixture: ASCTestFlightService {
    var gate: TabGate?
    var fails = false
    func fetchBuilds(appId: String) async throws -> [ASCBuild] { await gate?.wait(); return [cacheBuild] }
    func fetchBetaGroups(appId: String) async throws -> [ASCBetaGroup] { if fails { throw URLError(.timedOut) }; return [] }
    func fetchBetaLocalizations(appId: String) async throws -> [ASCBetaLocalization] { [] }
    func fetchBetaFeedback(appId: String, buildId: String) async throws -> [ASCBetaFeedback] {
        #expect(appId == "app-a")
        #expect(buildId == "build-a")
        await gate?.wait()
        if fails { throw URLError(.timedOut) }
        return [decodeTab(#"{"id":"feedback","attributes":{"comment":"Saved comment"}}"#)]
    }
}

@MainActor @Test func testFlightRejectsLateResultsAfterProjectSwitch() async throws {
    let manager = tabManager()
    let gate = TabGate()
    let task = Task { try? await manager.loadTestFlightTab(.builds, using: FlightFixture(gate: gate)) }
    await gate.entered()
    manager.resetProjectData(preserveCredentials: true)
    await gate.release()
    await task.value
    #expect(manager.builds.isEmpty)
}

@MainActor @Test func feedbackUsesFreshMemoryCacheAndRetainsDataAfterFailure() async {
    let manager = tabManager()
    let gate = TabGate()
    let first = Task { await manager.refreshBetaFeedback(buildId: "build-a", using: FlightFixture(gate: gate)) }
    await gate.entered()
    let second = Task { await manager.refreshBetaFeedback(buildId: "build-a", using: FlightFixture(gate: gate)) }
    await Task.yield()
    await gate.release()
    #expect(await first.value)
    #expect(await second.value)
    #expect(await gate.calls == 1)
    #expect(await manager.refreshBetaFeedback(buildId: "build-a", force: false, using: FlightFixture(fails: true)))
    #expect(!(await manager.refreshBetaFeedback(buildId: "build-a", using: FlightFixture(fails: true))))
    #expect(manager.betaFeedback["build-a"]?.first?.attributes.comment == "Saved comment")
    #expect(manager.tabError[.feedback] != nil)
}

private struct InformationFixture: ASCAppInformationService {
    var fails = false
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] { [cacheVersion] }
    func fetchAppInfo(appId: String) async throws -> ASCAppInfo { decodeTab(#"{"id":"info","attributes":{}}"#) }
    func fetchLocalizations(versionId: String) async throws -> [ASCVersionLocalization] { [cacheText] }
    func fetchAppInfoLocalizations(appInfoId: String) async throws -> [ASCAppInfoLocalization] {
        if fails { throw URLError(.timedOut) }
        return [decodeTab(#"{"id":"info-loc","attributes":{"locale":"de-DE","name":"Current name"}}"#)]
    }
}

@MainActor @Test func informationRefreshIsAtomicOnPartialFailure() async throws {
    let manager = tabManager()
    manager.localizations = []
    do {
        try await manager.refreshAppInformationMetadata(service: InformationFixture(fails: true), appId: "app-a")
        Issue.record("Expected a failed refresh")
    } catch { }
    #expect(manager.localizations.isEmpty)
    #expect(manager.appInfo == nil)
    try await manager.refreshAppInformationMetadata(service: InformationFixture(), appId: "app-a")
    #expect(manager.localizations.count == 1)
    #expect(manager.primaryAppInfoLocalization()?.attributes.name == "Current name")
}

@Test func previewCacheReusesDiskSeparatesAccountsAndRejectsBadDownloads() async throws {
    let root = temporaryCache()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = URL(string: "https://example.com/preview.png")!
    let cache = ASCScreenshotPreviewCache(directory: root, download: { _ in pixelPNG })
    #expect(await cache.data(scope: "a", url: url) == pixelPNG)
    let offline = ASCScreenshotPreviewCache(directory: root, download: { _ in throw URLError(.notConnectedToInternet) })
    #expect(await offline.data(scope: "a", url: url) == pixelPNG)
    #expect(await offline.data(scope: "b", url: url) == nil)
    #expect(await offline.data(scope: "a", url: url, now: Date().addingTimeInterval(ASCScreenshotPreviewCache.maximumAge + 10)) == nil)
    let invalid = ASCScreenshotPreviewCache(directory: root, download: { _ in Data("not an image".utf8) })
    #expect(await invalid.data(scope: "b", url: url) == nil)
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    let permissions = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test func previewCacheBoundsDiskUsage() async throws {
    let root = temporaryCache()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ASCScreenshotPreviewCache(directory: root, maximumBytes: pixelPNG.count * 2, maximumEntries: 3, download: { _ in pixelPNG })
    for index in 0..<5 { _ = await cache.data(scope: "a", url: URL(string: "https://example.com/\(index).png")!) }
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
    let sizes = try files.map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
    #expect(files.count <= 2)
    #expect(sizes.reduce(0, +) <= pixelPNG.count * 2)
}

@MainActor @Test func screenshotPreviewRejectsLateImageAfterProjectChange() async {
    let manager = tabManager()
    let gate = TabGate()
    let shot: ASCScreenshot = decodeTab(#"{"id":"s","attributes":{"imageAsset":{"templateUrl":"https://example.com/{w}x{h}.{f}","width":400,"height":800}}}"#)
    let task = Task {
        await manager.hydrateScreenshotImageCache(screenshots: ["set": [shot]], force: false, loader: { _ in
            await gate.wait()
            return NSImage(data: pixelPNG)
        })
    }
    await gate.entered()
    manager.resetProjectData(preserveCredentials: true)
    await gate.release()
    await task.value
    #expect(manager.screenshotImageCache.isEmpty)
}

@MainActor @Test func tabCacheEvictsOldEntries() async throws {
    let root = temporaryCache()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ASCTabCache(directory: root)
    let entry = try #require(ASCTabCacheEntry(manager: tabManager(), tab: .builds))
    for index in 0..<(ASCTabCache.maximumEntries + 2) { await cache.save(entry, account: "account-\(index)") }
    #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == ASCTabCache.maximumEntries)
}

@Test func previewCacheCoalescesConcurrentRequests() async {
    let root = temporaryCache()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = TabGate()
    let cache = ASCScreenshotPreviewCache(directory: root, download: { _ in await gate.wait(); return pixelPNG })
    let url = URL(string: "https://example.com/shared.png")!
    async let first = cache.data(scope: "a", url: url)
    async let second = cache.data(scope: "a", url: url)
    await gate.entered()
    await gate.release()
    #expect(await first == pixelPNG)
    #expect(await second == pixelPNG)
    #expect(await gate.calls == 1)
}

@MainActor @Test func screenshotURLChangeInvalidatesOldPreview() {
    let manager = tabManager()
    let old: ASCScreenshot = decodeTab(#"{"id":"s","attributes":{"imageAsset":{"templateUrl":"https://example.com/old.png"}}}"#)
    let new: ASCScreenshot = decodeTab(#"{"id":"s","attributes":{"imageAsset":{"templateUrl":"https://example.com/new.png"}}}"#)
    let set: ASCScreenshotSet = decodeTab(#"{"id":"set","attributes":{"screenshotDisplayType":"APP_IPHONE_67"}}"#)
    manager.updateScreenshotCache(locale: "de-DE", sets: [set], screenshots: ["set": [old]])
    manager.cacheScreenshotImage(NSImage(size: NSSize(width: 1, height: 1)), for: "s")
    manager.updateScreenshotCache(locale: "de-DE", sets: [set], screenshots: ["set": [new]])
    #expect(manager.cachedScreenshotImage(for: "s") == nil)
    #expect(manager.trackSlotsForDisplayType("APP_IPHONE_67", locale: "de-DE")[0]?.localImage == nil)
}

@MainActor @Test func screenshotURLChangeRejectsAlreadyLoadingOldPreview() async {
    let manager = tabManager()
    let old: ASCScreenshot = decodeTab(#"{"id":"s","attributes":{"imageAsset":{"templateUrl":"https://example.com/old.png"}}}"#)
    let new: ASCScreenshot = decodeTab(#"{"id":"s","attributes":{"imageAsset":{"templateUrl":"https://example.com/new.png"}}}"#)
    manager.updateScreenshotCache(locale: "de-DE", sets: [], screenshots: ["set": [old]])
    let gate = TabGate()
    let task = Task {
        await manager.hydrateScreenshotImageCache(screenshots: ["set": [old]], force: false, loader: { _ in
            await gate.wait()
            return NSImage(size: NSSize(width: 1, height: 1))
        })
    }
    await gate.entered()
    manager.updateScreenshotCache(locale: "de-DE", sets: [], screenshots: ["set": [new]])
    await gate.release()
    await task.value
    #expect(manager.cachedScreenshotImage(for: "s") == nil)
}

@Test func feedbackDecodesAppleSubmissionFields() throws {
    let response: ASCListResponse<ASCBetaFeedback> = decodeTab(#"{"data":[{"type":"betaFeedbackScreenshotSubmissions","id":"feedback-a","attributes":{"createdDate":"2026-10-19T10:00:00Z","comment":"Useful feedback","email":"tester@example.com","deviceModel":"iPhone17,1","osVersion":"18.0","screenshots":[{"url":"https://example.com/feedback.png","width":320,"height":640}]}}]}"#)
    let item = try #require(response.data.first)
    #expect(item.attributes.timestamp == "2026-10-19T10:00:00Z")
    #expect(item.attributes.emailAddress == "tester@example.com")
    #expect(item.attributes.screenshotUrl == "https://example.com/feedback.png")
    #expect(item.attributes.comment == "Useful feedback")
    let empty: ASCBetaFeedback = decodeTab(#"{"id":"empty","attributes":{}}"#)
    #expect(empty.attributes.screenshotUrl == nil)
}
