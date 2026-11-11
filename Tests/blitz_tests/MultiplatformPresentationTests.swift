import Foundation
import Testing
@testable import Blitz

private func platformDecode<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func platformApp(_ id: String = "app", bundle: String = "org.example.App") throws -> ASCApp {
    try platformDecode("{\"id\":\"\(id)\",\"attributes\":{\"name\":\"Example\",\"bundleId\":\"\(bundle)\"}}")
}

private func platformVersion(_ platform: String, id: String, state: String = "PREPARE_FOR_SUBMISSION") throws -> ASCAppStoreVersion {
    try platformDecode("{\"id\":\"\(id)\",\"attributes\":{\"versionString\":\"1.2.0\",\"platform\":\"\(platform)\",\"appStoreState\":\"\(state)\"}}")
}

@MainActor @Test func dashboardPreservesBothLocalProjectsForOneStoreApp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DashboardSummaryStore(cacheURL: root.appendingPathComponent("cache"), accountKeyOverride: "issuer:key")
    let projects = [Project(id: "ios", metadata: .init(name: "Mobile", type: .swift, platform: .iOS, bundleIdentifier: "org.example.App"), path: "/tmp/ios"),
                    Project(id: "mac", metadata: .init(name: "Mac", type: .swift, platform: .macOS, bundleIdentifier: "org.example.App"), path: "/tmp/mac")]
    let rows = store.rows(linking: projects, ascApps: [try platformApp()], projectStatuses: [:], iconURLs: [:])
    #expect(rows.count == 1)
    #expect(Set(rows[0].projectLinks?.map(\.projectId) ?? []) == ["ios", "mac"])
}

@MainActor @Test func dashboardLinksEveryTargetEvenWhenAnotherTargetIsSelected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DashboardSummaryStore(cacheURL: root.appendingPathComponent("cache"), accountKeyOverride: "issuer:key")
    let targets = [ProjectReleaseTarget(id: "mobile", platform: .iOS, bundleIdentifier: "org.example.Mobile"),
                   ProjectReleaseTarget(id: "desktop", platform: .macOS, bundleIdentifier: "org.example.Mac")]
    let project = Project(id: "both", metadata: .init(name: "Both", type: .swift, releaseTargets: targets,
        selectedReleaseTargetId: "mobile"), path: "/tmp/both")
    let rows = store.rows(linking: [project], ascApps: [try platformApp("ios", bundle: "org.example.Mobile"),
        try platformApp("mac", bundle: "org.example.Mac")], projectStatuses: [:], iconURLs: [:])
    #expect(rows.count == 2)
    #expect(Set(rows.flatMap { $0.projectLinks?.map(\.targetId) ?? [] }) == ["mobile", "desktop"])
}

@MainActor @Test func dashboardRejectsStoreBindingFromAnotherAccount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DashboardSummaryStore(cacheURL: root.appendingPathComponent("cache"), accountKeyOverride: "issuer:key")
    let target = ProjectReleaseTarget(id: "mac", platform: .macOS, bundleIdentifier: "org.example.App",
        storeBinding: .init(appId: "app", accountKey: "other:key", sku: nil, bundleIdentifier: "org.example.App"))
    let project = Project(id: "project", metadata: .init(name: "Mac", type: .swift, releaseTargets: [target]), path: "/tmp/project")
    let rows = store.rows(linking: [project], ascApps: [try platformApp()], projectStatuses: [:], iconURLs: [:])
    #expect(rows.first { $0.source == .asc }?.projectLinks?.isEmpty == true)
    #expect(rows.contains { $0.source == .localOnly })
}

@MainActor @Test func overviewCacheSeparatesPlatformsAndRejectsAnotherVersion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ASCOverviewCache(directory: root)
    let manager = ASCManager()
    manager.app = try platformApp()
    manager.releasePlatform = .iOS
    manager.appStoreVersions = [try platformVersion("IOS", id: "ios"), try platformVersion("MAC_OS", id: "mac")]
    manager.selectedVersionId = "ios"
    manager.localizations = [try platformDecode(#"{"id":"text-ios","attributes":{"locale":"de-DE","description":"iOS only"}}"#)]
    let entry = ASCOverviewCacheEntry(manager: manager)
    await cache.save(entry, account: "account")
    #expect(await cache.load(account: "account", bundle: "org.example.App", platform: .macOS) == nil)
    #expect(await cache.load(account: "account", bundle: "org.example.App", platform: .iOS, versionId: "other") == nil)
    #expect(await cache.load(account: "account", bundle: "org.example.App", platform: .iOS, versionId: "ios") != nil)
    manager.releasePlatform = .macOS
    manager.selectedVersionId = "mac"
    manager.localizations = []
    entry.apply(to: manager)
    #expect(manager.localizations.isEmpty)
    #expect(manager.selectedVersionId == "mac")
}

@MainActor @Test func platformSwitchInvalidatesCapturedWritesAndScreenshotDrafts() throws {
    let manager = ASCManager()
    manager.app = try platformApp()
    manager.loadedProjectId = "asc:org.example.App"
    manager.releasePlatform = .iOS
    manager.loadedReleaseTargetId = "ios"
    manager.appStoreVersions = [try platformVersion("IOS", id: "ios"), try platformVersion("MAC_OS", id: "mac")]
    manager.syncSelectedVersion()
    let before = try #require(manager.releaseOperationTarget())
    manager.selectedTestFlightBuildId = "ios-build"
    manager.trackSlots["old"] = [nil]
    manager.selectReleasePlatform(.macOS)
    #expect(!before.matches(manager))
    #expect(manager.selectedVersionId == "mac")
    #expect(manager.selectedTestFlightBuildId == nil)
    #expect(manager.trackSlots.isEmpty)
}

@MainActor @Test func macReadinessRequiresMacScreenshotsEvenWhenNoneExist() throws {
    let manager = ASCManager()
    manager.app = try platformApp()
    manager.releasePlatform = .macOS
    manager.appStoreVersions = [try platformVersion("MAC_OS", id: "mac")]
    let fields = manager.submissionReadiness.fields
    #expect(fields.contains { $0.label == "Mac Screenshots" && $0.value == nil })
    #expect(!fields.contains { $0.label == "iPhone Screenshots" })
}

@Test func dashboardShowsIndependentStatusesForSharedStoreRecord() throws {
    let status = ASCDashboardProjectStatus(versions: [try platformVersion("IOS", id: "ios", state: "READY_FOR_SALE"),
        try platformVersion("MAC_OS", id: "mac", state: "WAITING_FOR_REVIEW")], availability: .available)
    #expect(status.platformSummaries?["IOS"] == "Live")
    #expect(status.platformSummaries?["MAC_OS"] == "In Prüfung")
}
