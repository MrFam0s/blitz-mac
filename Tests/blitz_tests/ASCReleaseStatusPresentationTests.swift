import Testing
@testable import Blitz

@Test func releasePresentationSeparatesApprovalFromStoreAvailability() {
    let version = presentationVersion("current", state: "READY_FOR_SALE")
    let approval = ASCReleaseStatusPresentation.version(version, distributionReadyVersionID: "current")
    let unavailable = presentationStore(availability: .unavailable)
    let live = presentationStore(availability: .available, liveID: "current")

    #expect(approval.label == "Approved for distribution")
    #expect(approval.tone == .neutral)
    #expect(unavailable.label == "Not on the App Store")
    #expect(unavailable.tone == .neutral)
    #expect(live.label == "Live on the App Store")
    #expect(live.tone == .positive)
}

@Test func releasePresentationNeverCallsHistoricalReadyVersionLive() {
    for state in ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_VERSION"] {
        let historical = ASCReleaseStatusPresentation.version(
            presentationVersion("previous", state: state), distributionReadyVersionID: "current"
        )
        #expect(historical.label == "Previously released")
        #expect(historical.tone == .neutral)
    }
    let inconsistentIdentity = presentationStore(availability: .available, liveID: "previous")
    #expect(inconsistentIdentity.tone != .positive)
}

@Test func releasePresentationDoesNotTreatMissingOrFailedAvailabilityAsLive() {
    let missing = presentationStore(availability: nil, liveID: "current")
    let failed = presentationStore(availability: .available, liveID: "current", failed: true)
    let loading = presentationStore(availability: .available, liveID: "current", loading: true)

    #expect(missing.label == "Availability unknown")
    #expect(failed.label == "Availability unknown")
    #expect(loading.label == "Checking availability…")
    #expect([missing, failed, loading].allSatisfy { $0.tone == .neutral })
    #expect(failed.help.contains("Refresh"))
}

@Test func releasePresentationTerritoryAvailabilityAloneDoesNotProveALiveVersion() {
    let status = ASCReleaseStatusPresentation.store(
        distributionReadyVersionID: nil, liveVersionID: nil, availability: .available,
        isLoading: false, failed: false
    )
    #expect(status.label == "No live version")
    #expect(status.tone == .neutral)
}

@Test func releasePresentationPreservesReviewAndDraftStatuses() {
    let draft = ASCReleaseStatusPresentation.version(
        presentationVersion("draft", state: "PREPARE_FOR_SUBMISSION"), distributionReadyVersionID: "current"
    )
    let review = ASCReleaseStatusPresentation.version(
        presentationVersion("review", state: "WAITING_FOR_REVIEW"), distributionReadyVersionID: "current"
    )
    let rejected = ASCReleaseStatusPresentation.version(
        presentationVersion("rejected", state: "REJECTED"), distributionReadyVersionID: "current"
    )
    #expect(draft.label == "Draft")
    #expect(draft.tone == .warning)
    #expect(review.label == "Waiting for Review")
    #expect(review.tone == .review)
    #expect(rejected.label == "Rejected")
    #expect(rejected.tone == .rejected)
}

@Test func releasePresentationUsesModernStateBeforeLegacyReadyState() {
    let version = presentationVersion("current", state: "READY_FOR_SALE", modernState: "WAITING_FOR_REVIEW")
    let status = ASCReleaseStatusPresentation.version(version, distributionReadyVersionID: "current")
    #expect(status.label == "Waiting for Review")
    #expect(status.tone == .review)
}

private func presentationVersion(_ id: String, state: String, modernState: String? = nil) -> ASCAppStoreVersion {
    .init(id: id, attributes: .init(
        versionString: "1.0", appStoreState: state, releaseType: nil, createdDate: nil,
        copyright: nil, appVersionState: modernState
    ))
}

private func presentationStore(
    availability: ASCStoreAvailability?, liveID: String? = nil,
    loading: Bool = false, failed: Bool = false
) -> ASCStatusPresentation {
    ASCReleaseStatusPresentation.store(
        distributionReadyVersionID: "current", liveVersionID: liveID, availability: availability,
        isLoading: loading, failed: failed
    )
}
