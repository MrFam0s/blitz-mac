import Foundation
import Testing
@testable import Blitz

private func storeStateFixture<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@MainActor
private func storeStateManager(availability: ASCStoreAvailability? = nil) throws -> ASCManager {
    let manager = ASCManager()
    manager.app = try storeStateFixture(#"{"id":"123","attributes":{"name":"Example","bundleId":"org.example.test"}}"#)
    manager.appStoreVersions = [try storeStateFixture(#"{"id":"approved","attributes":{"versionString":"1.0","appStoreState":"READY_FOR_SALE","appVersionState":"READY_FOR_DISTRIBUTION","platform":"IOS","createdDate":"2026-01-01T00:00:00Z"}}"#)]
    manager.selectedVersionId = "approved"
    manager.storeAvailabilityContext = manager.currentStoreAvailabilityContext
    manager.storeAvailability = availability
    manager.storeAvailabilityUpdatedAt = availability == nil ? nil : Date()
    return manager
}

@Test func mcpVersionStatesIdentifyAppleWorkflowAndPreferModernState() throws {
    let version: ASCAppStoreVersion = try storeStateFixture(#"{"id":"review","attributes":{"versionString":"2.0","appStoreState":"READY_FOR_SALE","appVersionState":"WAITING_FOR_REVIEW","releaseType":"AFTER_APPROVAL","createdDate":"2026-02-01T00:00:00Z"}}"#)
    let payload = try #require(MCPExecutor.versionStatePayload(version))
    #expect(payload["state"] as? String == "WAITING_FOR_REVIEW")
    #expect(payload["stateKind"] as? String == "appleVersionWorkflow")
    #expect(payload["appVersionState"] as? String == "WAITING_FOR_REVIEW")
    #expect(payload["appStoreState"] as? String == "READY_FOR_SALE")
    #expect(payload["releaseType"] as? String == "AFTER_APPROVAL")
    #expect(payload["createdDate"] as? String == "2026-02-01T00:00:00Z")

    let legacy: ASCAppStoreVersion = try storeStateFixture(#"{"id":"legacy","attributes":{"versionString":"1.0","appStoreState":"READY_FOR_SALE"}}"#)
    let legacyPayload = try #require(MCPExecutor.versionStatePayload(legacy))
    #expect(legacyPayload["state"] as? String == "READY_FOR_SALE")
    #expect(legacyPayload["stateKind"] as? String == "appleVersionWorkflow")
    #expect(legacyPayload["appVersionState"] == nil)
    #expect(MCPExecutor.versionStatePayload(nil) == nil)
}

@Test(arguments: [ASCStoreAvailability.available, .unavailable])
func mcpAvailabilityPayloadIncludesOnlyConfirmedCheckTime(availability: ASCStoreAvailability) throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let payload = MCPExecutor.storeAvailabilityStatePayload(
        confirmed: availability, isLoading: false, failed: false, checkedAt: date
    )
    #expect(payload["state"] as? String == availability.rawValue)
    #expect(payload["error"] as? Bool == false)
    #expect(payload["checkedAt"] as? String == "2023-11-14T22:13:20Z")
    #expect(JSONSerialization.isValidJSONObject(payload))
}

@Test func mcpAvailabilityPayloadNeverPublishesAnUnconfirmedTimestamp() {
    let date = Date()
    for (confirmed, loading, failed, state) in [
        (ASCStoreAvailability.available, true, false, "checking"),
        (.available, false, true, "unknown"),
        (.unavailable, true, false, "checking"),
    ] {
        let payload = MCPExecutor.storeAvailabilityStatePayload(
            confirmed: confirmed, isLoading: loading, failed: failed, checkedAt: date
        )
        #expect(payload["state"] as? String == state)
        #expect(payload["error"] as? Bool == failed)
        #expect(payload["checkedAt"] == nil)
    }
    let unknown = MCPExecutor.storeAvailabilityStatePayload(
        confirmed: nil, isLoading: false, failed: false, checkedAt: date
    )
    #expect(unknown["state"] as? String == "unknown")
    #expect(unknown["error"] as? Bool == false)
    #expect(unknown["checkedAt"] == nil)
    let invalidDate = MCPExecutor.storeAvailabilityStatePayload(
        confirmed: .available, isLoading: false, failed: false,
        checkedAt: Date(timeIntervalSinceReferenceDate: .infinity)
    )
    #expect(invalidDate["checkedAt"] == nil)
}

@MainActor
@Test func everyMCPTabHeaderContainsTheSameConfirmedAvailability() throws {
    let manager = try storeStateManager(availability: .unavailable)
    for tab in AppTab.allCases {
        let header = MCPExecutor.tabStateHeader(for: tab, asc: manager)
        let availability = try #require(header["storeAvailability"] as? [String: Any])
        #expect(header["tab"] as? String == tab.rawValue)
        #expect(availability["state"] as? String == "unavailable")
        #expect(availability["error"] as? Bool == false)
        #expect(availability["checkedAt"] as? String != nil)
        #expect(JSONSerialization.isValidJSONObject(header))
    }
}

@MainActor
@Test func mcpOverviewDoesNotCallAnUnavailableApprovedVersionLive() throws {
    let manager = try storeStateManager(availability: .unavailable)
    let overview = MCPExecutor.tabStateASCOverview(manager)
    #expect(overview["liveVersion"] == nil)
    #expect((overview["distributionReadyVersion"] as? [String: Any])?["id"] as? String == "approved")
    #expect((overview["selectedVersion"] as? [String: Any])?["state"] as? String == "READY_FOR_DISTRIBUTION")
    #expect((overview["latestVersion"] as? [String: Any])?["stateKind"] as? String == "appleVersionWorkflow")
    // The separate metadata-copying source must remain available to internal workflows.
    #expect(manager.liveVersion?.id == "approved")
}

@MainActor
@Test func mcpOverviewOnlyPublishesConfirmedCurrentLiveVersion() throws {
    let manager = try storeStateManager(availability: .available)
    let overview = MCPExecutor.tabStateASCOverview(manager)
    #expect((overview["liveVersion"] as? [String: Any])?["id"] as? String == "approved")

    let removed: ASCAppStoreVersion = try storeStateFixture(#"{"id":"removed","attributes":{"versionString":"2.0","appStoreState":"READY_FOR_SALE","appVersionState":"REMOVED_FROM_SALE","platform":"IOS","createdDate":"2026-02-01T00:00:00Z"}}"#)
    manager.appStoreVersions.insert(removed, at: 0)
    let afterRemoval = MCPExecutor.tabStateASCOverview(manager)
    #expect(afterRemoval["liveVersion"] == nil)
    #expect(afterRemoval["distributionReadyVersion"] == nil)
    #expect((afterRemoval["latestVersion"] as? [String: Any])?["state"] as? String == "REMOVED_FROM_SALE")
}

@MainActor
@Test(arguments: ["stale", "failed", "loading", "appChanged", "neverChecked"])
func mcpOverviewAndHeaderDoNotExposeStaleOrUnconfirmedStoreEvidence(scenario: String) throws {
    let manager = try storeStateManager(availability: .available)
    switch scenario {
    case "stale": manager.storeAvailabilityUpdatedAt = Date().addingTimeInterval(-121)
    case "failed": manager.storeAvailabilityFailed = true
    case "loading": manager.isStoreAvailabilityLoading = true
    case "appChanged":
        manager.app = try storeStateFixture(#"{"id":"456","attributes":{"name":"Other","bundleId":"org.example.other"}}"#)
    default: manager.resetStoreAvailability()
    }
    #expect(MCPExecutor.tabStateASCOverview(manager)["liveVersion"] == nil)
    let header = MCPExecutor.tabStateHeader(for: .appInformation, asc: manager)
    let availability = try #require(header["storeAvailability"] as? [String: Any])
    #expect(availability["state"] as? String == (scenario == "loading" ? "checking" : "unknown"))
    #expect(availability["error"] as? Bool == (scenario == "failed"))
    #expect(availability["checkedAt"] == nil)
}

@MainActor
@Test func availabilityDiagnosticsSeparateCurrentAvailabilityFromHistoricalEvents() throws {
    let manager = try storeStateManager(availability: .unavailable)
    manager.submissionHistoryEvents = [ASCSubmissionHistoryEvent(
        id: "past-release", versionId: "approved", versionString: "1.0", eventType: .live,
        appleState: "READY_FOR_SALE", occurredAt: "2026-01-01T00:00:00Z",
        source: .reviewSubmission, accuracy: .derived, submissionId: nil, note: nil
    )]
    let snapshot = manager.diagnosticSnapshot(reason: "offline_status_check")
    #expect(snapshot.contains("  liveVersion: nil\n"))
    #expect(snapshot.contains("  distributionReadyVersion: id=approved"))
    #expect(snapshot.contains("appleState=READY_FOR_DISTRIBUTION appVersionState=READY_FOR_DISTRIBUTION appStoreState=READY_FOR_SALE"))
    #expect(snapshot.contains("  storeAvailability:\n    state: unavailable\n    error: false\n    checkedAt:"))
    #expect(snapshot.contains("id=past-release type=live version=1.0 occurredAt=2026-01-01T00:00:00Z"))

    manager.storeAvailabilityFailed = true
    let failed = manager.diagnosticSnapshot(reason: "offline_status_check")
    #expect(failed.contains("  storeAvailability:\n    state: unknown\n    error: true"))
    #expect(!failed.contains("    checkedAt:"))
    #expect(failed.contains("  liveVersion: nil\n"))
}
