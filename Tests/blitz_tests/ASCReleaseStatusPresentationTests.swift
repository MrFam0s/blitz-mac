import Testing
@testable import Blitz

@Test func releasePresentationSeparatesApprovalFromStoreAvailability() {
    L10n.$overrideLanguage.withValue("de") {
        let version = presentationVersion("current", state: "READY_FOR_SALE")
        let approval = ASCReleaseStatusPresentation.version(version, distributionReadyVersionID: "current")
        let unavailable = presentationStore(availability: .unavailable)
        let live = presentationStore(availability: .available, liveID: "current")

        #expect(approval.label == "Zur Verteilung freigegeben")
        #expect(approval.tone == .neutral)
        #expect(unavailable.label == "Nicht im App Store")
        #expect(unavailable.tone == .neutral)
        #expect(live.label == "Im App Store verfügbar")
        #expect(live.tone == .positive)
    }
}

@Test func releasePresentationNeverCallsHistoricalReadyVersionLive() {
    L10n.$overrideLanguage.withValue("de") {
        for state in ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_VERSION"] {
            let historical = ASCReleaseStatusPresentation.version(
                presentationVersion("previous", state: state), distributionReadyVersionID: "current"
            )
            #expect(historical.label == "Früher veröffentlicht")
            #expect(historical.tone == .neutral)
        }
        let inconsistentIdentity = presentationStore(availability: .available, liveID: "previous")
        #expect(inconsistentIdentity.tone != .positive)
    }
}

@Test func releasePresentationDoesNotTreatMissingOrFailedAvailabilityAsLive() {
    L10n.$overrideLanguage.withValue("de") {
        let missing = presentationStore(availability: nil, liveID: "current")
        let failed = presentationStore(availability: .available, liveID: "current", failed: true)
        let loading = presentationStore(availability: .available, liveID: "current", loading: true)

        #expect(missing.label == "Verfügbarkeit unbekannt")
        #expect(failed.label == "Verfügbarkeit unbekannt")
        #expect(loading.label == "Verfügbarkeit wird geprüft …")
        #expect([missing, failed, loading].allSatisfy { $0.tone == .neutral })
        #expect(failed.help.contains("Aktualisiere"))
    }
}

@Test func releasePresentationTerritoryAvailabilityAloneDoesNotProveALiveVersion() {
    L10n.$overrideLanguage.withValue("de") {
        let status = ASCReleaseStatusPresentation.store(
            distributionReadyVersionID: nil, liveVersionID: nil, availability: .available,
            isLoading: false, failed: false
        )
        #expect(status.label == "Keine veröffentlichte Version")
        #expect(status.tone == .neutral)
    }
}

@Test func releasePresentationPreservesReviewAndDraftStatuses() {
    L10n.$overrideLanguage.withValue("de") {
        let draft = ASCReleaseStatusPresentation.version(
            presentationVersion("draft", state: "PREPARE_FOR_SUBMISSION"), distributionReadyVersionID: "current"
        )
        let review = ASCReleaseStatusPresentation.version(
            presentationVersion("review", state: "WAITING_FOR_REVIEW"), distributionReadyVersionID: "current"
        )
        let rejected = ASCReleaseStatusPresentation.version(
            presentationVersion("rejected", state: "REJECTED"), distributionReadyVersionID: "current"
        )
        #expect(draft.label == "Entwurf")
        #expect(draft.tone == .warning)
        #expect(review.label == "Wartet auf Prüfung")
        #expect(review.tone == .review)
        #expect(rejected.label == "Abgelehnt")
        #expect(rejected.tone == .rejected)
    }
}

@Test func releasePresentationUsesModernStateBeforeLegacyReadyState() {
    L10n.$overrideLanguage.withValue("de") {
        let version = presentationVersion("current", state: "READY_FOR_SALE", modernState: "WAITING_FOR_REVIEW")
        let status = ASCReleaseStatusPresentation.version(version, distributionReadyVersionID: "current")
        #expect(status.label == "Wartet auf Prüfung")
        #expect(status.tone == .review)
    }
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
