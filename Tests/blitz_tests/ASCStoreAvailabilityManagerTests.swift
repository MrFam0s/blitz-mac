import Foundation
import Testing
@testable import Blitz

private struct StorefrontStub: ASCStoreAvailabilityFetching {
    var availability: ASCStoreAvailability = .available
    var failure = false
    func fetchStoreAvailability(appId: String) async throws -> ASCStoreAvailability {
        if failure { throw URLError(.timedOut) }
        return availability
    }
}

@MainActor
private func storefrontManager() throws -> ASCManager {
    let manager = ASCManager()
    manager.loadedProjectId = "project-a"
    manager.app = try JSONDecoder().decode(ASCApp.self, from: Data(#"{"id":"app-a","attributes":{"bundleId":"org.example.a","name":"Example"}}"#.utf8))
    manager.appStoreVersions = try JSONDecoder().decode([ASCAppStoreVersion].self, from: Data(#"[{"id":"ready","attributes":{"versionString":"1.0","appStoreState":"READY_FOR_SALE","appVersionState":"READY_FOR_DISTRIBUTION","platform":"IOS"}}]"#.utf8))
    return manager
}

@MainActor
@Test func storefrontSeparatesDistributionReadinessFromConfirmedLive() async throws {
    let manager = try storefrontManager()
    #expect(manager.distributionReadyVersion?.id == "ready")
    #expect(manager.storeLiveVersion == nil)
    await manager.refreshStoreAvailability(using: StorefrontStub())
    #expect(manager.storeLiveVersion?.id == "ready")
    await manager.refreshStoreAvailability(using: StorefrontStub(availability: .unavailable), force: true)
    #expect(manager.storeLiveVersion == nil)
    #expect(manager.confirmedStoreAvailability == .unavailable)
    #expect(manager.distributionReadyVersion?.id == "ready")
    // Storefront presentation does not disable version creation or metadata copying.
    #expect(manager.liveVersion?.id == "ready")
    #expect(manager.canCreateUpdate)
}

@MainActor
@Test func storefrontFailureAndExpiredEvidenceCannotKeepLiveBadge() async throws {
    let manager = try storefrontManager()
    await manager.refreshStoreAvailability(using: StorefrontStub())
    manager.storeAvailabilityUpdatedAt = Date().addingTimeInterval(-121)
    #expect(manager.confirmedStoreAvailability == nil)
    #expect(manager.storeLiveVersion == nil)
    await manager.refreshStoreAvailability(using: StorefrontStub())
    #expect(manager.storeLiveVersion != nil)
    await manager.refreshStoreAvailability(using: StorefrontStub(failure: true), force: true)
    #expect(manager.confirmedStoreAvailability == nil)
    #expect(manager.storeAvailabilityFailed)
    #expect(manager.storeAvailabilityUpdatedAt == nil)
}

@MainActor
@Test func storefrontEvidenceCannotCrossAccountOrProjectContext() async throws {
    let manager = try storefrontManager()
    await manager.refreshStoreAvailability(using: StorefrontStub())
    manager.credentialActivationRevision += 1
    #expect(manager.confirmedStoreAvailability == nil)
    await manager.refreshStoreAvailability(using: StorefrontStub())
    #expect(manager.storeLiveVersion != nil)
    manager.loadedProjectId = "another-project"
    #expect(manager.confirmedStoreAvailability == nil)
}

private actor StorefrontGate: ASCStoreAvailabilityFetching {
    private var requested = false
    private var waitingForRequest: CheckedContinuation<Void, Never>?
    private var waitingForResponse: CheckedContinuation<ASCStoreAvailability, Never>?
    private(set) var calls = 0
    func fetchStoreAvailability(appId: String) async throws -> ASCStoreAvailability {
        calls += 1; requested = true
        waitingForRequest?.resume(); waitingForRequest = nil
        return await withCheckedContinuation { waitingForResponse = $0 }
    }
    func wait() async { if !requested { await withCheckedContinuation { waitingForRequest = $0 } } }
    func finish(_ value: ASCStoreAvailability) { waitingForResponse?.resume(returning: value); waitingForResponse = nil }
}

@MainActor
@Test func storefrontLateReplyCannotReplaceNewProjectEvidenceOrClearItsLoader() async throws {
    let manager = try storefrontManager()
    let old = StorefrontGate()
    let oldTask = Task { await manager.refreshStoreAvailability(using: old) }
    await old.wait()
    manager.resetProjectData(preserveCredentials: true)
    let new = try storefrontManager()
    manager.app = new.app
    manager.loadedProjectId = "project-b"
    manager.appStoreVersions = new.appStoreVersions
    let fresh = StorefrontGate()
    let freshTask = Task { await manager.refreshStoreAvailability(using: fresh) }
    await fresh.wait()
    await old.finish(.available)
    await oldTask.value
    #expect(manager.isStoreAvailabilityLoading)
    #expect(manager.confirmedStoreAvailability == nil)
    await fresh.finish(.unavailable)
    await freshTask.value
    #expect(manager.confirmedStoreAvailability == .unavailable)
    #expect(!manager.isStoreAvailabilityLoading)
}

@MainActor
@Test func storefrontSharesInflightReadAndUsesFreshEvidence() async throws {
    let manager = try storefrontManager()
    let gate = StorefrontGate()
    let first = Task { await manager.refreshStoreAvailability(using: gate) }
    await gate.wait()
    let second = Task { await manager.refreshStoreAvailability(using: gate) }
    await Task.yield()
    #expect(await gate.calls == 1)
    await gate.finish(.available)
    await first.value; await second.value
    await manager.refreshStoreAvailability(using: StorefrontStub(failure: true))
    #expect(manager.confirmedStoreAvailability == .available)
    #expect(!manager.storeAvailabilityFailed)
}

@MainActor
@Test func storefrontCanceledWaiterDoesNotCancelSharedRefresh() async throws {
    let manager = try storefrontManager()
    await manager.refreshStoreAvailability(using: StorefrontStub())
    let gate = StorefrontGate()
    let task = Task { await manager.refreshStoreAvailability(using: gate, force: true) }
    await gate.wait()
    #expect(manager.storeLiveVersion == nil)
    let otherTab = Task { await manager.refreshStoreAvailability(using: gate) }
    await Task.yield()
    task.cancel()
    await gate.finish(.available)
    await task.value
    await otherTab.value
    #expect(await gate.calls == 1)
    #expect(manager.storeLiveVersion?.id == "ready")
    #expect(!manager.storeAvailabilityFailed)
}

@MainActor
@Test func storefrontDiskCacheDoesNotInventAvailabilityEvidence() async throws {
    let source = try storefrontManager()
    await source.refreshStoreAvailability(using: StorefrontStub())
    let entry = ASCOverviewCacheEntry(manager: source)
    let restored = ASCManager()
    restored.loadedProjectId = source.loadedProjectId
    entry.apply(to: restored)
    #expect(restored.distributionReadyVersion?.id == "ready")
    #expect(restored.storeLiveVersion == nil)
    #expect(restored.confirmedStoreAvailability == nil)
}

@MainActor
@Test func storefrontIgnoresReplacedLegacyReadyVersionAndUsesModernState() async throws {
    let manager = try storefrontManager()
    manager.appStoreVersions = try JSONDecoder().decode([ASCAppStoreVersion].self, from: Data(#"[{"id":"modern","attributes":{"versionString":"2.0","appVersionState":"READY_FOR_DISTRIBUTION","platform":"IOS","createdDate":"2026-11-01T00:00:00Z"}},{"id":"legacy","attributes":{"versionString":"1.0","appStoreState":"READY_FOR_SALE","appVersionState":"REPLACED_WITH_NEW_VERSION","platform":"IOS","createdDate":"2026-10-01T00:00:00Z"}}]"#.utf8))
    await manager.refreshStoreAvailability(using: StorefrontStub())
    #expect(manager.storeLiveVersion?.id == "modern")
    manager.appStoreVersions.removeFirst()
    #expect(manager.storeLiveVersion == nil)
}

private actor StorefrontTabTransport {
    private(set) var calls = 0
    func request(_ method: String, _ path: String, _ headers: [String: String], _ body: Data?) throws -> ASCDaemonClient.HTTPResponse {
        calls += 1
        let json: String
        if path.contains("/appAvailabilityV2") {
            json = #"{"data":{"type":"appAvailabilities","id":"availability-a"}}"#
        } else if path.contains("/territoryAvailabilities") {
            json = #"{"data":[{"type":"territoryAvailabilities","id":"region-a","attributes":{"available":false,"contentStatuses":["CANNOT_SELL"]}}],"links":{"next":null}}"#
        } else { throw URLError(.unsupportedURL) }
        return .init(statusCode: 200, headers: [:], contentType: "application/json", body: Data(json.utf8))
    }
}

@MainActor
@Test func storefrontInitialTabVisitReusesEvidenceButExplicitRefreshRechecks() async throws {
    let manager = try storefrontManager()
    manager.credentials = .init(issuerId: "test-issuer", keyId: "test-key", privateKey: "test-only")
    let transport = StorefrontTabTransport()
    manager.service = AppStoreConnectService(requestTransport: { try await transport.request($0, $1, $2, $3) })
    await manager.refreshStoreAvailability(using: StorefrontStub())
    await manager.ensureTabData(.analytics)
    #expect(await transport.calls == 0)
    #expect(manager.confirmedStoreAvailability == .available)
    await manager.refreshTabData(.analytics)
    #expect(await transport.calls == 2)
    #expect(manager.confirmedStoreAvailability == .unavailable)
}
