// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// Current Apple review facts, never a deduction from a reply or a local journal's
/// historical submission acknowledgement. Version relationships are mandatory.
struct ASCReviewProgress {
    enum Phase: String, Equatable {
        case draft, needsResolution, readyToSubmit, readyToResubmit
        case waitingForReview, inReview, accepted, unavailable
    }
    let phase: Phase
    let submissionID: String?
    let itemState: String?
    let submissionState: String?
    let latestMessage: IrisFeedbackCycle.Message?
    let ambiguousSubmission: Bool
    var statusConflict = false

    var isRecovery: Bool { phase == .needsResolution || phase == .readyToResubmit }
    var canPreviewSubmission: Bool {
        [.draft, .needsResolution, .readyToSubmit, .readyToResubmit].contains(phase)
    }
    var requiresResolution: Bool { phase == .needsResolution && submissionID != nil }

    init(version: ASCAppStoreVersion?, submissions: [ASCReviewSubmission],
         itemsBySubmissionID: [String: [ASCReviewSubmissionItem]],
         matchedFeedback: [IrisFeedbackCycle] = [], isComplete: Bool = true) {
        latestMessage = matchedFeedback.flatMap(\.messages).filter { Self.date($0.createdAt) != nil }
            .max { Self.date($0.createdAt)! < Self.date($1.createdAt)! }
        guard let version else {
            phase = .unavailable; submissionID = nil; itemState = nil; submissionState = nil; ambiguousSubmission = false
            return
        }
        let state = ASCReleaseStatus.normalize(version.attributes.effectiveState)
        let platform = ASCReleaseStatus.normalize(version.attributes.platform)
        let matching = submissions.filter { submission in
            let submissionPlatform = ASCReleaseStatus.normalize(submission.attributes.platform)
            return (submissionPlatform.isEmpty || platform.isEmpty || submissionPlatform == platform)
                && (itemsBySubmissionID[submission.id] ?? []).contains { $0.appStoreVersionId == version.id }
        }
        let active = matching.filter { !["COMPLETE", "CANCELED"].contains(ASCReleaseStatus.normalize($0.attributes.state)) }
        ambiguousSubmission = active.count > 1
        let selected = active.count == 1 ? active.first : (active.isEmpty ? matching.max {
            (Self.date($0.attributes.submittedDate) ?? .distantPast) < (Self.date($1.attributes.submittedDate) ?? .distantPast)
        } : nil)
        submissionID = selected?.id
        self.submissionState = selected?.attributes.state
        let items = selected.flatMap { itemsBySubmissionID[$0.id] } ?? []
        let item = items.first { $0.appStoreVersionId == version.id }
        itemState = item?.attributes.state
        guard isComplete, !ambiguousSubmission else { phase = .unavailable; return }
        let submissionState = ASCReleaseStatus.normalize(selected?.attributes.state)
        if selected != nil && !["WAITING_FOR_REVIEW", "IN_REVIEW", "IN_PROGRESS", "UNRESOLVED_ISSUES", "READY_FOR_REVIEW", "COMPLETE", "CANCELED"].contains(submissionState) {
            phase = .unavailable; return
        }
        let released = ASCReleaseStatus.isLive(state) || ["ACCEPTED", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE"].contains(state)
        let versionQueued = ["WAITING_FOR_REVIEW", "IN_REVIEW"].contains(state)
        statusConflict = (submissionState == "WAITING_FOR_REVIEW" && state != "WAITING_FOR_REVIEW")
            || (["IN_REVIEW", "IN_PROGRESS"].contains(submissionState) && state != "IN_REVIEW")
            || (["UNRESOLVED_ISSUES", "READY_FOR_REVIEW"].contains(submissionState) && (released || versionQueued))
            || (submissionState == "COMPLETE" && (versionQueued || ASCReleaseStatus.rejectedStates.contains(state)))
        guard !statusConflict else { phase = .unavailable; return }
        if submissionState == "WAITING_FOR_REVIEW" { phase = .waitingForReview; return }
        if ["IN_REVIEW", "IN_PROGRESS"].contains(submissionState) { phase = .inReview; return }
        if submissionState == "UNRESOLVED_ISSUES" {
            let rejected = items.contains { ASCReleaseStatus.normalize($0.attributes.state) == "REJECTED" }
            let ready = !items.isEmpty && items.allSatisfy {
                let state = ASCReleaseStatus.normalize($0.attributes.state)
                return ["READY_FOR_REVIEW", "ACCEPTED", "APPROVED"].contains(state)

            }
            phase = rejected ? .needsResolution : (ready ? .readyToResubmit : .unavailable)
            return
        }
        if state == "WAITING_FOR_REVIEW" { phase = .waitingForReview; return }
        if state == "IN_REVIEW" { phase = .inReview; return }
        if ASCReleaseStatus.isLive(state) || ["ACCEPTED", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE"].contains(state) {
            phase = .accepted; return
        }
        if ASCReleaseStatus.rejectedStates.contains(state) { phase = .needsResolution; return }
        if state == "READY_FOR_REVIEW" || submissionState == "READY_FOR_REVIEW" { phase = .readyToSubmit; return }
        phase = ASCReleaseStatus.isEditable(state) ? .draft : .unavailable
    }

    var payload: [String: Any] {
        let nextAction: String
        switch phase {
        case .needsResolution: nextAction = "resolveReviewIssues"
        case .readyToResubmit: nextAction = "prepareResubmission"
        case .readyToSubmit, .draft: nextAction = "reviewAndSubmit"
        case .waitingForReview, .inReview: nextAction = "waitForApple"
        case .accepted: nextAction = "checkReleaseStatus"
        case .unavailable: nextAction = "refreshAndInspect"
        }
        return ["phase": phase.rawValue, "submissionId": submissionID as Any? ?? NSNull(),
                "submissionState": submissionState as Any? ?? NSNull(), "itemState": itemState as Any? ?? NSNull(),
                "nextAction": nextAction, "requiresResolutionConfirmation": requiresResolution,
                "ambiguousSubmission": ambiguousSubmission, "statusConflict": statusConflict,
                "latestMessageSender": latestMessage?.sender?.rawValue as Any? ?? NSNull(),
                "latestMessageAt": latestMessage?.createdAt as Any? ?? NSNull(),
                "replyIsSubmissionConfirmation": false]
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
