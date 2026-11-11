import Foundation
import Testing
@testable import Blitz

@Test func dashboardStatusIgnoresOlderRejectedVersionAfterLiveRelease() {
    let status = ASCDashboardProjectStatus(versions: [
        makeVersion(id: "live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
        makeVersion(id: "rejected", state: "REJECTED", createdDate: "2026-03-01T00:00:00Z"),
    ])

    #expect(status.isLiveOnStore)
    #expect(!status.isPendingReview)
    #expect(!status.isRejected)
}

@Test func dashboardStatusCountsRejectedUpdateAlongsideLiveRelease() {
    let status = ASCDashboardProjectStatus(versions: [
        makeVersion(id: "rejected", state: "REJECTED", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ])

    #expect(status.isLiveOnStore)
    #expect(!status.isPendingReview)
    #expect(status.isRejected)
}

@Test func dashboardStatusCountsPendingReviewUpdateAlongsideLiveRelease() {
    let status = ASCDashboardProjectStatus(versions: [
        makeVersion(id: "review", state: "WAITING_FOR_REVIEW", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ])

    #expect(status.isLiveOnStore)
    #expect(status.isPendingReview)
    #expect(!status.isRejected)
}

@Test func dashboardReadyVersionRequiresAvailableTerritoriesWhenAvailabilityIsKnown() {
    let versions = [
        makeVersion(id: "review", state: "WAITING_FOR_REVIEW", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z", appVersionState: "READY_FOR_DISTRIBUTION"),
    ]
    let candidate = ASCDashboardProjectStatus(versions: versions)
    let available = ASCDashboardProjectStatus(versions: versions, availability: .available)
    let unavailable = ASCDashboardProjectStatus(versions: versions, availability: .unavailable)

    #expect(candidate.isLiveOnStore)
    #expect(candidate.storeAvailability == nil)
    #expect(available.isLiveOnStore)
    #expect(!available.isUnavailableOnStore)
    #expect(!unavailable.isLiveOnStore)
    #expect(unavailable.isUnavailableOnStore)
    #expect(unavailable.isPendingReview)
}

@Test func dashboardAvailableTerritoryDoesNotTurnAnUnreleasedAppLive() {
    let status = ASCDashboardProjectStatus(versions: [
        makeVersion(id: "draft", state: "PREPARE_FOR_SUBMISSION", createdDate: "2026-03-21T00:00:00Z"),
    ], availability: .available)

    #expect(!status.isLiveOnStore)
    #expect(!status.isUnavailableOnStore)
}

@Test(arguments: ["REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE", "REPLACED_WITH_NEW_VERSION"])
func dashboardLatestPublicationStopsOlderLiveAndReviewStatuses(state: String) {
    let status = ASCDashboardProjectStatus(versions: [
        makeVersion(id: "latest", state: state, createdDate: "2026-03-23T00:00:00Z"),
        makeVersion(id: "rejected", state: "REJECTED", createdDate: "2026-03-22T00:00:00Z"),
        makeVersion(id: "review", state: "WAITING_FOR_REVIEW", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "old-live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ], availability: .available)

    #expect(!status.isLiveOnStore)
    #expect(!status.isPendingReview)
    #expect(!status.isRejected)
}

@Test func dashboardReviewAfterRemovalRemainsCurrentWithoutRestoringLive() {
    let status = ASCDashboardProjectStatus(versions: [
        makeVersion(id: "review", state: "WAITING_FOR_REVIEW", createdDate: "2026-03-23T00:00:00Z"),
        makeVersion(id: "removed", state: "DEVELOPER_REMOVED_FROM_SALE", createdDate: "2026-03-22T00:00:00Z"),
        makeVersion(id: "old-live", state: "READY_FOR_SALE", createdDate: "2026-03-20T00:00:00Z"),
    ])

    #expect(!status.isLiveOnStore)
    #expect(status.isPendingReview)
    #expect(!status.isRejected)
}

@Test func dashboardRemovalAndReviewAreResolvedIndependentlyForEachPlatform() {
    let versions = [
        makeVersion(id: "ios-removed", state: "REMOVED_FROM_SALE", createdDate: "2026-03-24T00:00:00Z", platform: "IOS"),
        makeVersion(id: "ios-old-live", state: "READY_FOR_SALE", createdDate: "2026-03-23T00:00:00Z", platform: "IOS"),
        makeVersion(id: "mac-review", state: "WAITING_FOR_REVIEW", createdDate: "2026-03-22T00:00:00Z", platform: "MAC_OS"),
        makeVersion(id: "mac-live", state: "READY_FOR_DISTRIBUTION", createdDate: "2026-03-21T00:00:00Z", platform: "MAC_OS"),
    ]
    let available = ASCDashboardProjectStatus(versions: versions, availability: .available)
    let unavailable = ASCDashboardProjectStatus(versions: versions, availability: .unavailable)

    #expect(available.isLiveOnStore)
    #expect(available.isPendingReview)
    #expect(!unavailable.isLiveOnStore)
    #expect(unavailable.isPendingReview)
    #expect(unavailable.isUnavailableOnStore)
}

@Test func dashboardUsesModernVersionStateBeforeLegacyState() throws {
    let versions = try JSONDecoder().decode([ASCAppStoreVersion].self, from: Data("""
    [
        {"id":"review","attributes":{"versionString":"2.0","appStoreState":"READY_FOR_SALE","appVersionState":"WAITING_FOR_REVIEW","createdDate":"2026-03-23T00:00:00Z"}},
        {"id":"replaced","attributes":{"versionString":"1.0","appStoreState":"READY_FOR_SALE","appVersionState":"REPLACED_WITH_NEW_VERSION","createdDate":"2026-03-22T00:00:00Z"}}
    ]
    """.utf8))
    let status = ASCDashboardProjectStatus(versions: versions, availability: .available)

    #expect(versions[0].attributes.effectiveState == "WAITING_FOR_REVIEW")
    #expect(!status.isLiveOnStore)
    #expect(status.isPendingReview)
}

@Test func dashboardAcceptsModernLiveStateWithoutLegacyState() throws {
    let version = try JSONDecoder().decode(ASCAppStoreVersion.self, from: Data("""
    {"id":"live","attributes":{"versionString":"1.0","appVersionState":"READY_FOR_DISTRIBUTION"}}
    """.utf8))

    #expect(version.attributes.appStoreState == nil)
    #expect(ASCDashboardProjectStatus(versions: [version], availability: .available).isLiveOnStore)
}

@Test func dashboardAvailabilityKeepsLegacyCacheDecodableAndRoundTripsEvidence() throws {
    let legacy = try JSONDecoder().decode(ASCDashboardProjectStatus.self, from: Data("""
    {"isLiveOnStore":true,"isPendingReview":false,"isRejected":false}
    """.utf8))
    #expect(legacy.isLiveOnStore)
    #expect(legacy.storeAvailability == nil)
    #expect(!legacy.isUnavailableOnStore)

    let unavailable = ASCDashboardProjectStatus(
        isLiveOnStore: true, isPendingReview: false, isRejected: true, storeAvailability: .unavailable
    )
    #expect(!unavailable.isLiveOnStore)
    #expect(unavailable.isRejected)
    #expect(try JSONDecoder().decode(ASCDashboardProjectStatus.self, from: JSONEncoder().encode(unavailable)) == unavailable)
}

@Test func releaseStatusSortsVersionsByNewestCreatedDateFirst() {
    let sorted = ASCReleaseStatus.sortedVersionsByRecency([
        makeVersion(id: "old", state: "READY_FOR_SALE", createdDate: "2026-03-01T00:00:00Z"),
        makeVersion(id: "new", state: "WAITING_FOR_REVIEW", createdDate: "2026-03-21T00:00:00Z"),
        makeVersion(id: "middle", state: "REJECTED", createdDate: "2026-03-10T00:00:00Z"),
    ])

    #expect(sorted.map(\.id) == ["new", "middle", "old"])
}

@Test func submissionHistoryMapsInvalidBinaryToSubmissionError() {
    #expect(ASCReleaseStatus.submissionHistoryEventType(forVersionState: "INVALID_BINARY") == .submissionError)
    #expect(ASCReleaseStatus.reviewSubmissionEventType(forVersionState: "INVALID_BINARY") == .submissionError)
}

@Test func reviewSubmissionStaysSubmittedForWaitingForReview() {
    #expect(ASCReleaseStatus.reviewSubmissionEventType(forVersionState: "WAITING_FOR_REVIEW") == .submitted)
}

private func makeVersion(
    id: String,
    state: String,
    createdDate: String,
    platform: String? = nil,
    appVersionState: String? = nil
) -> ASCAppStoreVersion {
    ASCAppStoreVersion(
        id: id,
        attributes: ASCAppStoreVersion.Attributes(
            versionString: id,
            appStoreState: state,
            releaseType: nil,
            createdDate: createdDate,
            copyright: nil,
            platform: platform,
            appVersionState: appVersionState
        )
    )
}
