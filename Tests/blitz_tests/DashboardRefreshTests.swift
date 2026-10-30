import Foundation
import Testing
@testable import Blitz

@MainActor
@Test func dashboardRefreshFailureKeepsTimestampAndCacheUntilSuccessfulRetry() async throws {
    let file = dashboardRefreshTestFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account")
    await store.refresh(for: "account", accountKey: "account", service: DashboardTestFetcher(), projects: [])
    let updated = try #require(store.refreshedAt)
    let rows = store.appRows
    await store.refresh(for: "account", accountKey: "account", service: DashboardTestFetcher(failure: URLError(.notConnectedToInternet)), projects: [], force: true)
    #expect(store.loadIssue == .offline)
    #expect(store.isShowingSavedData)
    #expect(store.refreshedAt == updated)
    #expect(store.appRows == rows)
    #expect(store.shouldRefresh(for: "account"))
    let restarted = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account")
    #expect(restarted.refreshedAt == updated)
    #expect(restarted.isShowingSavedData)
    await store.refresh(for: "account", accountKey: "account", service: DashboardTestFetcher(), projects: [], force: true)
    #expect(store.loadIssue == nil)
    #expect(!store.isShowingSavedData)
}

@MainActor
@Test func dashboardPartialFailurePreservesPreviousStatusAndMarksItStale() async {
    let file = dashboardRefreshTestFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account")
    await store.refresh(for: "account", accountKey: "account", service: DashboardTestFetcher(), projects: [])
    #expect(store.summary.liveCount == 1)
    await store.refresh(for: "account", accountKey: "account", service: DashboardTestFetcher(statusFailure: true), projects: [], force: true)
    #expect(store.summary.liveCount == 1)
    #expect(store.unavailableStatusBundleIDs == ["org.example.test"])
    #expect(store.loadIssue == .partialStatuses(1))
    let restarted = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account")
    #expect(restarted.loadIssue == .partialStatuses(1))
    await store.refresh(for: "account", accountKey: "account", service: DashboardTestFetcher(), projects: [], force: true)
    #expect(store.loadIssue == nil)
    #expect(store.unavailableStatusBundleIDs.isEmpty)
}

@MainActor
@Test func dashboardFirstFailureDoesNotInventZeroCountsOrFreshStatus() async {
    let file = dashboardRefreshTestFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account")
    await store.refresh(for: "account", accountKey: "account", service: DashboardTestFetcher(failure: ASCError.httpError(401, "private response")), projects: [])
    #expect(!store.hasLoadedSummary)
    #expect(store.refreshedAt == nil)
    #expect(store.loadIssue == .authentication)
    await store.refresh(for: "account", accountKey: "account", service: DashboardTestFetcher(statusFailure: true), projects: [], force: true)
    #expect(store.appRows.first?.status == nil)
    #expect(store.loadIssue == .partialStatuses(1))
}

@MainActor
@Test func dashboardLateResponseCannotReplaceAnotherAccountsData() async {
    let file = dashboardRefreshTestFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "new")
    let old = DelayedDashboardFetcher()
    let task = Task { await store.refresh(for: "old", accountKey: "old", service: old, projects: []) }
    await old.waitForRequest()
    await store.refresh(for: "new", accountKey: "new", service: DashboardTestFetcher(empty: true), projects: [])
    await old.finish()
    await task.value
    #expect(store.cacheKey == "new")
    #expect(store.appRows.isEmpty)
    #expect(store.loadIssue == nil)
    #expect(!store.isLoadingSummary)
}

@MainActor
@Test func dashboardCancellationIsNotReportedAsAnOutage() async {
    let file = dashboardRefreshTestFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account")
    await store.refresh(for: "account", accountKey: "account", service: DashboardTestFetcher(failure: CancellationError()), projects: [])
    #expect(store.loadIssue == nil)
    #expect(!store.isLoadingSummary)
}

@Test func dashboardErrorsHaveActionableMessagesWithoutRawResponseData() {
    #expect(DashboardLoadIssue.from(ASCError.httpError(401, "secret")) == .authentication)
    #expect(DashboardLoadIssue.from(ASCError.httpError(403, "forbidden")) == .permissions)
    #expect(DashboardLoadIssue.from(ASCError.httpError(429, "limited")) == .rateLimited)
    #expect(DashboardLoadIssue.from(ASCError.httpError(403, "latest agreement")) == .agreement)
    #expect(!DashboardLoadIssue.from(ASCError.httpError(500, "secret")).message.contains("secret"))
}

private func dashboardRefreshTestFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("cache.json")
}

private struct DashboardTestFetcher: DashboardFetching {
    var failure: Error? = nil
    var statusFailure = false
    var empty = false
    var iconURL: URL? = nil
    var iconFailure = false
    func fetchAllApps(appStoreStateFilter: String?) async throws -> [ASCApp] {
        if let failure { throw failure }
        if empty { return [] }
        return [ASCApp(id: "1", attributes: .init(bundleId: "org.example.test", name: "Test", primaryLocale: nil,
                                                vendorNumber: nil, contentRightsDeclaration: nil), relationships: nil)]
    }
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] {
        if statusFailure { throw URLError(.timedOut) }
        return try JSONDecoder().decode([ASCAppStoreVersion].self, from: Data("""
        [{"id":"v1","attributes":{"versionString":"1.0","appStoreState":"READY_FOR_SALE","platform":"IOS"}}]
        """.utf8))
    }
    func fetchAppStoreIconURL(app: ASCApp, dimension: Int) async throws -> URL? {
        #expect(dimension == 1024)
        if iconFailure { throw URLError(.timedOut) }
        return iconURL
    }
}

private actor DelayedDashboardFetcher: DashboardFetching {
    private var requested = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var responseWaiter: CheckedContinuation<Void, Never>?
    func fetchAllApps(appStoreStateFilter: String?) async throws -> [ASCApp] {
        requested = true
        requestWaiter?.resume(); requestWaiter = nil
        await withCheckedContinuation { responseWaiter = $0 }
        return try await DashboardTestFetcher().fetchAllApps(appStoreStateFilter: nil)
    }
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] { [] }
    func fetchAppStoreIconURL(app: ASCApp, dimension: Int) async throws -> URL? { nil }
    func waitForRequest() async { if !requested { await withCheckedContinuation { requestWaiter = $0 } } }
    func finish() { responseWaiter?.resume(); responseWaiter = nil }
}

@MainActor
@Test func dashboardCredentialRemovalInvalidatesAnInFlightRefresh() async {
    let file = dashboardRefreshTestFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "old")
    let old = DelayedDashboardFetcher()
    let task = Task { await store.refresh(for: "old", accountKey: "old", service: old, projects: []) }
    await old.waitForRequest()
    store.markUnavailable(for: "no-creds", accountKey: nil, issue: .missingCredentials)
    await old.finish()
    await task.value
    #expect(store.cacheKey == "no-creds")
    #expect(store.appRows.isEmpty)
    #expect(store.loadIssue == .missingCredentials)
}

@MainActor
@Test func dashboardReadsLegacyCacheWithoutAnInventedTimestamp() throws {
    let file = dashboardRefreshTestFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
    {"accountKey":"account","summary":{"liveCount":0,"pendingCount":0,"rejectedCount":0},"projectStatuses":{},"appRows":[]}
    """.utf8).write(to: file)
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account")
    #expect(store.hasLoadedSummary)
    #expect(store.refreshedAt == nil)
    #expect(store.isShowingSavedData)
    #expect(store.shouldRefresh(for: "account"))
}

@MainActor
@Test func dashboardRefreshUpdatesIconURLAndPreservesItOnLookupFailure() async throws {
    let file = dashboardRefreshTestFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = DashboardSummaryStore(cacheURL: file, accountKeyOverride: "account")
    let oldURL = try #require(URL(string: "https://example.invalid/old-icon.png"))
    let newURL = try #require(URL(string: "https://example.invalid/new-icon.png"))
    await store.refresh(for: "account", accountKey: "account", service: DashboardTestFetcher(iconURL: oldURL), projects: [])
    #expect(store.appRows.first?.iconURL == oldURL)
    #expect(store.iconRefreshRevision == 0)
    await store.refresh(for: "account", accountKey: "account", service: DashboardTestFetcher(iconURL: newURL), projects: [], force: true)
    #expect(store.appRows.first?.iconURL == newURL)
    #expect(store.iconRefreshRevision == 1)
    await store.refresh(for: "account", accountKey: "account", service: DashboardTestFetcher(iconFailure: true), projects: [], force: true)
    #expect(store.appRows.first?.iconURL == newURL)
    #expect(store.iconRefreshRevision == 2)
}
