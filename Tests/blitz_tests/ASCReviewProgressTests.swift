import Foundation
import Testing
@testable import Blitz

@Test func reviewReplyDoesNotResubmitRejectedItem() {
    let progress = reviewProgress(state: "REJECTED", submissionState: "UNRESOLVED_ISSUES", itemState: "REJECTED", reply: true)
    #expect(progress.phase == .needsResolution)
    #expect(progress.requiresResolution)
    #expect(progress.latestMessage?.sender == .developer)
}

@Test func resolvedItemStillNeedsFinalResubmission() {
    #expect(reviewProgress(state: "REJECTED", submissionState: "UNRESOLVED_ISSUES", itemState: "REJECTED", resolved: true).phase == .needsResolution)
    #expect(reviewProgress(state: "READY_FOR_REVIEW", submissionState: "UNRESOLVED_ISSUES", itemState: "READY_FOR_REVIEW").phase == .readyToResubmit)
}

@Test func readyForReviewIsNotSubmitted() {
    let progress = reviewProgress(state: "READY_FOR_REVIEW", submissionState: "READY_FOR_REVIEW", itemState: "READY_FOR_REVIEW")
    #expect(progress.phase == .readyToSubmit)
    #expect(progress.canPreviewSubmission)
}

@Test func queuedSubmissionWithContradictoryVersionRequiresFreshRead() {
    let progress = reviewProgress(state: "REJECTED", submissionState: "WAITING_FOR_REVIEW", itemState: "READY_FOR_REVIEW", reply: true)
    #expect(progress.phase == .unavailable)
    #expect(progress.statusConflict)
    #expect(!progress.canPreviewSubmission)
    #expect(!progress.isRecovery)
}

@Test func reviewingAndAcceptedStatesDoNotInviteResubmission() {
    #expect(reviewProgress(state: "IN_REVIEW", submissionState: "IN_REVIEW", itemState: "READY_FOR_REVIEW").phase == .inReview)
    let accepted = reviewProgress(state: "PENDING_DEVELOPER_RELEASE", submissionState: "COMPLETE", itemState: "ACCEPTED", reply: true)
    #expect(accepted.phase == .accepted)
    #expect(!accepted.canPreviewSubmission)
}

@Test func unknownOrPartiallyLoadedItemsNeverClaimReady() {
    #expect(reviewProgress(state: "REJECTED", submissionState: "UNRESOLVED_ISSUES", itemState: nil).phase == .unavailable)
    let partial = ASCReviewProgress(version: reviewVersion(), submissions: [], itemsBySubmissionID: [:], isComplete: false)
    #expect(partial.phase == .unavailable)
    #expect(!partial.canPreviewSubmission)
}

@Test func undatedActiveReviewWinsOverOldCompletedReview() {
    let progress = ASCReviewProgress(version: reviewVersion(state: "READY_FOR_REVIEW"),
        submissions: [reviewSubmission("old", "COMPLETE", date: "2026-11-16T10:00:00Z"), reviewSubmission("active", "UNRESOLVED_ISSUES")],
        itemsBySubmissionID: ["old": [reviewItem("old-item", "ACCEPTED")], "active": [reviewItem("new-item", "READY_FOR_REVIEW")]])
    #expect(progress.submissionID == "active")
    #expect(progress.phase == .readyToResubmit)
}

@Test func otherVersionOrPlatformReviewDoesNotChangeSelectedVersionStatus() {
    let foreign = ASCReviewSubmission(id: "other", attributes: .init(state: "WAITING_FOR_REVIEW", submittedDate: nil, platform: "MAC_OS"))
    let progress = ASCReviewProgress(version: reviewVersion(), submissions: [foreign, reviewSubmission("different-version", "WAITING_FOR_REVIEW")],
        itemsBySubmissionID: ["other": [reviewItem("item", "READY_FOR_REVIEW")], "different-version": [reviewItem("item2", "READY_FOR_REVIEW", versionID: "foreign")]])
    #expect(progress.phase == .needsResolution)
    #expect(progress.submissionID == nil)
}

@Test func ambiguousActiveReviewsRequireInspection() {
    let progress = ASCReviewProgress(version: reviewVersion(), submissions: [reviewSubmission("a", "UNRESOLVED_ISSUES"), reviewSubmission("b", "READY_FOR_REVIEW")],
        itemsBySubmissionID: ["a": [reviewItem("a", "REJECTED")], "b": [reviewItem("b", "READY_FOR_REVIEW")]])
    #expect(progress.ambiguousSubmission)
    #expect(progress.phase == .unavailable)
    #expect(!progress.canPreviewSubmission)
}

@Test func latestAppleQuestionIsNotReportedAsLatestDeveloperReply() {
    var cycle = IrisFeedbackCycle.empty(id: "cycle", occurredAt: "2026-11-17T10:00:00Z")
    cycle.messages = [.init(id: "reply", body: "reply", createdAt: "2026-11-17T10:00:00Z", sender: .developer),
                      .init(id: "question", body: "question", createdAt: "2026-11-17T11:00:00.001Z", sender: .apple)]
    let progress = ASCReviewProgress(version: reviewVersion(), submissions: [], itemsBySubmissionID: [:], matchedFeedback: [cycle])
    #expect(progress.latestMessage?.sender == .apple)
    #expect(progress.phase == .needsResolution)
}

private func reviewProgress(state: String, submissionState: String, itemState: String?, resolved: Bool? = nil, reply: Bool = false) -> ASCReviewProgress {
    var cycle = IrisFeedbackCycle.empty(id: "cycle", occurredAt: "2026-11-17T10:00:00Z")
    if reply { cycle.messages = [.init(id: "reply", body: "Please continue review", createdAt: "2026-11-17T11:00:00Z", sender: .developer)] }
    return ASCReviewProgress(version: reviewVersion(state: state), submissions: [reviewSubmission("submission", submissionState)],
        itemsBySubmissionID: ["submission": [reviewItem("item", itemState, resolved: resolved)]], matchedFeedback: [cycle])
}
private func reviewVersion(state: String = "REJECTED") -> ASCAppStoreVersion {
    .init(id: "version", attributes: .init(versionString: "1.2.1", appStoreState: state, releaseType: "AFTER_APPROVAL", createdDate: nil, copyright: nil, platform: "IOS"))
}
private func reviewSubmission(_ id: String, _ state: String, date: String? = nil) -> ASCReviewSubmission {
    .init(id: id, attributes: .init(state: state, submittedDate: date, platform: "IOS"))
}
private func reviewItem(_ id: String, _ state: String?, resolved: Bool? = nil, versionID: String = "version") -> ASCReviewSubmissionItem {
    .init(id: id, attributes: .init(state: state, resolved: resolved, createdDate: nil), relationships: .init(appStoreVersion: .init(data: .init(type: "appStoreVersions", id: versionID))))
}

@Test func unknownAndCancelingReviewsNeverBecomeEditableDrafts() {
    for state in ["CANCELING", "UNKNOWN", ""] {
        let progress = reviewProgress(state: "PREPARE_FOR_SUBMISSION", submissionState: state, itemState: "READY_FOR_REVIEW")
        #expect(progress.phase == .unavailable)
        #expect(!progress.canPreviewSubmission)
    }
}

@Test func coherentQueueIsConfirmedAndCannotResubmit() {
    let progress = reviewProgress(state: "WAITING_FOR_REVIEW", submissionState: "WAITING_FOR_REVIEW", itemState: "READY_FOR_REVIEW", reply: true)
    #expect(progress.phase == .waitingForReview)
    #expect(!progress.statusConflict)
    #expect(!progress.canPreviewSubmission)
}

@Test func releasedVersionWithUnresolvedSubmissionCannotClaimComplete() {
    for state in ["READY_FOR_SALE", "PENDING_DEVELOPER_RELEASE", "ACCEPTED"] {
        let progress = reviewProgress(state: state, submissionState: "UNRESOLVED_ISSUES", itemState: "REJECTED")
        #expect(progress.phase == .unavailable)
        #expect(progress.statusConflict)
        #expect(!progress.canPreviewSubmission)
    }
}
