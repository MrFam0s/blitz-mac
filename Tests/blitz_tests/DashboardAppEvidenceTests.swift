import Foundation
import Testing
@testable import Blitz

@MainActor
@Test func dashboardObservedDatesIgnoreFetchTimeIconsAndVersionOrderAndSurviveRestart() async throws {
    let file = evidenceCacheURL()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account", now: { now })
    var fetcher = EvidenceDashboardFetcher()
    fetcher.versions = [evidenceVersion("new", date: "2026-11-20T10:00:00.500Z"),
                        evidenceVersion("old", date: "2026-11-19T10:00:00Z")]
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [])
    let initial = try #require(store.rows(linking: []).first)
    #expect(initial.lastChangedAt == nil)
    #expect(initial.latestVersionCreatedAt == ISO8601DateFormatter().date(from: "2026-11-20T10:00:00Z")?.addingTimeInterval(0.5))
    #expect(initial.sortDate == initial.latestVersionCreatedAt)
    now = now.addingTimeInterval(60)
    fetcher.versions.reverse()
    fetcher.iconURL = URL(string: "https://example.invalid/new-icon.png")
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [], force: true)
    #expect(store.appRows.first?.lastChangedAt == nil)
    #expect(store.appRows.first?.sortDate == initial.sortDate)
    #expect(store.refreshedAt == now)
    fetcher.name = "Renamed App"
    now = now.addingTimeInterval(60)
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [], force: true)
    let changedAt = now
    #expect(store.rows(linking: []).first?.lastChangedAt == changedAt)
    let restored = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account", now: { now })
    #expect(restored.rows(linking: []).first?.lastChangedAt == changedAt)
    #expect(restored.rows(linking: []).first?.platformCodes == ["IOS"])
    now = now.addingTimeInterval(60)
    await restored.refresh(for: "account", accountKey: "account", service: fetcher, projects: [], force: true)
    #expect(restored.appRows.first?.lastChangedAt == changedAt)
}

@MainActor
@Test func dashboardEvidenceRetainsPlatformsThroughAvailabilityFailureWithoutInventingChangeOnRecovery() async throws {
    let file = evidenceCacheURL()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account", now: { now })
    var fetcher = EvidenceDashboardFetcher()
    fetcher.versions = [evidenceVersion("ios", platform: "IOS", state: "READY_FOR_SALE"),
                        evidenceVersion("mac", platform: "MAC_OS", state: "READY_FOR_SALE")]
    fetcher.availabilityFailure = true
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [])
    #expect(store.appRows.first?.platformCodes == ["IOS", "MAC_OS"])
    #expect(store.appRows.first?.status == nil)
    #expect(store.appRows.first?.lastChangedAt == nil)
    fetcher.availabilityFailure = false
    now = now.addingTimeInterval(60)
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [], force: true)
    #expect(store.appRows.first?.status?.isLiveOnStore == true)
    #expect(store.appRows.first?.lastChangedAt == nil)
    fetcher.versionsFailure = true
    now = now.addingTimeInterval(60)
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [], force: true)
    #expect(store.appRows.first?.platformCodes == ["IOS", "MAC_OS"])
    #expect(store.unavailableStatusBundleIDs == [fetcher.bundleID])
    #expect(store.appRows.first?.lastChangedAt == nil)
    fetcher.versionsFailure = false
    now = now.addingTimeInterval(60)
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [], force: true)
    #expect(store.appRows.first?.lastChangedAt == nil)
    fetcher.availability = .unavailable
    now = now.addingTimeInterval(60)
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [], force: true)
    #expect(store.appRows.first?.lastChangedAt == now)
    #expect(store.appRows.first?.status?.isUnavailableOnStore == true)
}

@MainActor
@Test func dashboardEvidenceTracksSemanticVersionChangesAndClearsRemovedPlatforms() async {
    let file = evidenceCacheURL()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account", now: { now })
    var fetcher = EvidenceDashboardFetcher()
    fetcher.versions = [evidenceVersion("ios", platform: "IOS"), evidenceVersion("mac", platform: "MAC_OS")]
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [])
    now = now.addingTimeInterval(60)
    fetcher.versions = [evidenceVersion("ios", platform: "IOS", state: "WAITING_FOR_REVIEW")]
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [], force: true)
    #expect(store.rows(linking: []).first?.platformCodes == ["IOS"])
    #expect(store.rows(linking: []).first?.lastChangedAt == now)
    now = now.addingTimeInterval(60)
    fetcher.versions = []
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [], force: true)
    #expect(store.rows(linking: []).first?.platformCodes == [])
    #expect(store.rows(linking: []).first?.latestVersionCreatedAt == nil)
    #expect(store.rows(linking: []).first?.lastChangedAt == now)
}

@MainActor
@Test func dashboardEvidenceDistinguishesUnknownPlatformsAndDoesNotInferStorePlatformsFromLocalTargets() async throws {
    let file = evidenceCacheURL()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account")
    var fetcher = EvidenceDashboardFetcher()
    fetcher.versions = [evidenceVersion("ios", platform: " ios "), evidenceVersion("unknown", platform: nil),
                        evidenceVersion("vision", platform: "VISION_OS")]
    let macTarget = ProjectReleaseTarget(id: "mac", platform: .macOS, bundleIdentifier: fetcher.bundleID)
    let linkedProject = Project(id: "project", metadata: BlitzProjectMetadata(name: "App", type: .swift,
                               releaseTargets: [macTarget], selectedReleaseTargetId: "mac"), path: "/tmp/app")
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [linkedProject])
    let rows = store.rows(linking: [linkedProject])
    #expect(rows.count == 1)
    #expect(rows.first?.platformCodes == ["IOS", "UNKNOWN", "VISION_OS"])
    #expect(rows.first?.projectLinks?.first?.platform == .macOS)
    let legacyMetadata = try JSONDecoder().decode(BlitzProjectMetadata.self, from: Data("""
    {"name":"Unknown","type":"swift"}
    """.utf8))
    let unknownProject = Project(id: "legacy", metadata: legacyMetadata, path: "/tmp/unknown")
    #expect(DashboardAppRow.localOnly(project: unknownProject).platformCodes == nil)
    #expect(DashboardAppRow.localOnly(project: linkedProject, target: macTarget).platformCodes == ["MAC_OS"])
    #expect(DashboardAppRow.localOnly(project: linkedProject, target: macTarget).sortDate == nil)
}

@MainActor
@Test func dashboardStoreRecordsStaySeparateAndEvidenceIsAccountScoped() async {
    let file = evidenceCacheURL()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account", now: { now })
    var fetcher = EvidenceDashboardFetcher()
    fetcher.addSeparateMacApp = true
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [])
    #expect(store.appRows.count == 2)
    #expect(store.appRows.first { $0.ascAppId == "app" }?.platformCodes == ["IOS"])
    #expect(store.appRows.first { $0.ascAppId == "mac-app" }?.platformCodes == ["MAC_OS"])
    fetcher.name = "Changed"
    now = now.addingTimeInterval(60)
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [], force: true)
    #expect(store.appRows.first { $0.ascAppId == "app" }?.lastChangedAt == now)
    now = now.addingTimeInterval(60)
    await store.refresh(for: "other", accountKey: "other", service: fetcher, projects: [], force: true)
    #expect(store.appRows.allSatisfy { $0.lastChangedAt == nil })
    let otherAccount = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account")
    #expect(otherAccount.appRows.isEmpty)
}

@MainActor
@Test func dashboardFirstSuccessfulEvidenceAfterFailureDoesNotInventAnObservedChange() async {
    let file = evidenceCacheURL()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account")
    var fetcher = EvidenceDashboardFetcher()
    fetcher.versionsFailure = true
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [])
    #expect(store.appRows.first?.sortDate == nil)
    fetcher.versionsFailure = false
    await store.refresh(for: "account", accountKey: "account", service: fetcher, projects: [], force: true)
    #expect(store.appRows.first?.lastChangedAt == nil)
    #expect(store.appRows.first?.latestVersionCreatedAt != nil)
}

private func evidenceCacheURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("dashboard.json")
}

private func evidenceVersion(_ id: String, platform: String? = "IOS", state: String = "PREPARE_FOR_SUBMISSION",
                             date: String? = "2026-11-20T10:00:00Z") -> ASCAppStoreVersion {
    ASCAppStoreVersion(id: id, attributes: .init(versionString: "1.0", appStoreState: state,
        releaseType: nil, createdDate: date, copyright: nil, platform: platform))
}

private struct EvidenceDashboardFetcher: DashboardFetching {
    var name = "App"
    let bundleID = "org.example.dashboard"
    var versions = [evidenceVersion("version")]
    var versionsFailure = false
    var availability = ASCStoreAvailability.available
    var availabilityFailure = false
    var iconURL: URL? = nil
    var addSeparateMacApp = false

    func fetchAllApps(appStoreStateFilter: String?) async throws -> [ASCApp] {
        var result = [app(id: "app", bundleID: bundleID)]
        if addSeparateMacApp { result.append(app(id: "mac-app", bundleID: bundleID + ".mac")) }
        return result
    }
    private func app(id: String, bundleID: String) -> ASCApp {
        ASCApp(id: id, attributes: .init(bundleId: bundleID, name: name, primaryLocale: nil,
               vendorNumber: nil, contentRightsDeclaration: nil), relationships: nil)
    }
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] {
        if versionsFailure { throw URLError(.timedOut) }
        return appId == "mac-app" ? [evidenceVersion("mac", platform: "MAC_OS")] : versions
    }
    func fetchStoreAvailability(appId: String) async throws -> ASCStoreAvailability {
        if availabilityFailure { throw URLError(.timedOut) }
        return availability
    }
    func fetchAppStoreIconURL(app: ASCApp, dimension: Int) async throws -> URL? { iconURL }
}
