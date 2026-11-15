import Foundation
import Testing
@testable import Blitz

private let jointItems: [ReleaseReviewItem] = [
    .init(type: .inAppPurchaseVersions, id: "iap-v1"),
    .init(type: .subscriptionVersions, id: "sub-v1"),
    .init(type: .subscriptionGroupVersions, id: "group-v1")
]

private func jointDirectory() -> URL {
    FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("joint-release-\(UUID().uuidString)")
}

private func jointTarget(_ root: URL, items: [ReleaseReviewItem] = jointItems) -> ReleaseWorkflowTarget {
    .init(projectID: "project", projectPath: root.path, appID: "app", bundleID: "org.example.App",
          platform: "IOS", accountKey: "issuer:key", versionID: "version", buildID: "build", reviewItems: items)
}

/// Simulates successful Apple effects independently of delivery/journal progress,
/// so loss at each boundary can be tested without a real account.
private actor JointWorkflowAPI: ReleaseWorkflowAPI {
    nonisolated let accountKey = "issuer:key"
    var draft: String?
    var appItem: String?
    var itemIDs: [String: String] = [:]
    var content = "product-and-review-screenshot-hash"
    var submitted = false
    var creates = 0
    var adds: [String: Int] = [:]
    var submits = 0
    var failPhase: ReleaseSubmissionPhase?
    var failItemKey: String?
    var loseCreateReply = false
    var failHTTP: Int?
    var missingAttempt = false

    func fail(at phase: ReleaseSubmissionPhase?, item: String? = nil, loseCreateReply: Bool = false,
              httpStatus: Int? = nil, missingAttempt: Bool = false) {
        failPhase = phase; failItemKey = item; self.loseCreateReply = loseCreateReply
        failHTTP = httpStatus; self.missingAttempt = missingAttempt
    }
    func changeContent() { content = "changed-review-screenshot" }
    func replaceItem(_ key: String, with id: String?) { itemIDs[key] = id }
    func replaceAppItem(_ id: String?) { appItem = id }

    func snapshot(_ target: ReleaseWorkflowTarget) async throws -> ReleaseWorkflowSnapshot {
        let complete = appItem != nil && Set(itemIDs.keys) == Set(target.reviewItems.map(\.key))
        return .init(appID: target.appID, bundleID: target.bundleID, versionID: target.versionID,
                     platform: target.platform, versionString: "1.0", buildID: target.buildID,
                     buildNumber: "1", buildValid: true, attachedBuildID: target.buildID,
                     appleState: submitted ? "WAITING_FOR_REVIEW" : (appItem == nil ? "PREPARE_FOR_SUBMISSION" : "READY_FOR_REVIEW"),
                     releaseType: "MANUAL", contentDigest: content, submissionID: draft,
                     hasSubmissionConflict: draft != nil, submissionState: draft == nil ? nil : (submitted ? "WAITING_FOR_REVIEW" : "READY_FOR_REVIEW"),
                     canResumeSubmission: draft != nil && !submitted,
                     submissionItemID: appItem, submissionItemsComplete: complete, reviewItemIDs: itemIDs)
    }
    func readiness(_ target: ReleaseWorkflowTarget) async throws -> ReleaseWorkflowValidation {
        .init(ready: true, blocking: 0, warnings: 0, unverified: 0, checkIDs: ["joint.products"])
    }
    func setReleaseMode(_ mode: ReleaseWorkflowMode, target: ReleaseWorkflowTarget) async throws {
        throw ReleaseWorkflowError.unsafeState // All fixtures deliberately use MANUAL.
    }
    func emit(_ value: ReleaseSubmissionProgress,
              progress: @escaping @Sendable (ReleaseSubmissionProgress) async throws -> Void) async throws {
        try await progress(value)
        if value.phase == failPhase && (failItemKey == nil || value.reviewItem?.key == failItemKey) {
            if let failHTTP { throw ReleaseWorkflowAPIError.httpStatus(failHTTP) }
            if !missingAttempt {
                // Apple accepted the item, but the transport reply was lost.
                if value.phase == .addingVersion { adds["app", default: 0] += 1; appItem = "app-item" }
                if value.phase == .addingReviewItem, let item = value.reviewItem {
                    adds[item.key, default: 0] += 1; itemIDs[item.key] = "item-\(item.id)"
                }
            }
            throw URLError(.timedOut)
        }
    }
    func submit(_ target: ReleaseWorkflowTarget, expectedContentDigest: String, expectedFingerprintVersion: Int?,
                expectedReleaseMode: ReleaseWorkflowMode, resumingSubmissionID: String?,
                progress: @escaping @Sendable (ReleaseSubmissionProgress) async throws -> Void) async throws -> String? {
        if let resumingSubmissionID {
            #expect(resumingSubmissionID == draft)
        } else {
            try await emit(.init(phase: .creatingSubmission), progress: progress)
            creates += 1; draft = "submission"
            if loseCreateReply { throw URLError(.timedOut) }
            try await emit(.init(phase: .submissionCreated, submissionID: draft), progress: progress)
        }
        if appItem == nil {
            try await emit(.init(phase: .addingVersion, submissionID: draft), progress: progress)
            adds["app", default: 0] += 1; appItem = "app-item"
            try await emit(.init(phase: .versionAdded, submissionID: draft, submissionItemID: appItem), progress: progress)
        }
        for item in target.reviewItems where itemIDs[item.key] == nil {
            try await emit(.init(phase: .addingReviewItem, submissionID: draft, submissionItemID: appItem, reviewItem: item), progress: progress)
            adds[item.key, default: 0] += 1; itemIDs[item.key] = "item-\(item.id)"
            try await emit(.init(phase: .reviewItemAdded, submissionID: draft, submissionItemID: appItem,
                                 reviewItem: item, reviewItemID: itemIDs[item.key]), progress: progress)
        }
        try await emit(.init(phase: .verifyingContent, submissionID: draft, submissionItemID: appItem), progress: progress)
        #expect(content == expectedContentDigest)
        try await emit(.init(phase: .submitting, submissionID: draft, submissionItemID: appItem), progress: progress)
        submits += 1; submitted = true
        try await emit(.init(phase: .acknowledged, submissionID: draft, submissionItemID: appItem), progress: progress)
        return draft
    }
}

@Test func jointReleaseTargetSelectionIsCanonicalUniqueAndPreservesLegacyEncoding() throws {
    let root = jointDirectory()
    let a = jointTarget(root), b = jointTarget(root, items: jointItems.reversed())
    #expect(a == b)
    #expect(try ReleaseWorkflowService.digest(a) == ReleaseWorkflowService.digest(b))
    try a.validate()
    for items in [[jointItems[0], jointItems[0]], [.init(type: .inAppPurchaseVersions, id: "bad/id")],
                  (0..<200).map({ ReleaseReviewItem(type: .inAppPurchaseVersions, id: "v\($0)") })] {
        #expect(throws: ReleaseWorkflowError.self) { try jointTarget(root, items: items).validate() }
    }
    let appOnly = jointTarget(root, items: [])
    let encoded = try JSONEncoder().encode(appOnly)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["reviewItems"] == nil)
    #expect(try JSONDecoder().decode(ReleaseWorkflowTarget.self, from: encoded) == appOnly)
    #expect(object["releaseTargetId"] == nil)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ReleaseReviewItem.self, from: Data(#"{"type":"inAppPurchases","id":"parent"}"#.utf8))
    }
}

@Test func jointReleaseJournalsAllItemsAndConfirmsOnlyCompleteSubmission() async throws {
    let root = jointDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = JointWorkflowAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let plan = try await service.prepare(target: jointTarget(root), mode: .manual)
    #expect(plan.target.reviewItems.count == 3)
    _ = try await service.validate(operationID: plan.operationID, accountKey: "issuer:key")
    let done = try await service.submit(operationID: plan.operationID, accountKey: "issuer:key", confirmationDigest: plan.confirmationDigest)
    #expect(done.state == .submitted)
    #expect(done.reviewItemIDs?.count == 3)
    #expect(await api.creates == 1)
    #expect(await api.submits == 1)
    #expect(await api.adds.values.allSatisfy { $0 == 1 })
    _ = try await service.submit(operationID: plan.operationID, accountKey: "issuer:key", confirmationDigest: plan.confirmationDigest)
    #expect(await api.submits == 1)
}

@Test func jointReleaseRecoversEveryKnownPartialBoundaryWithoutDuplicateItems() async throws {
    let cases: [(ReleaseSubmissionPhase, String?)] = [(.submissionCreated, nil), (.addingVersion, nil), (.versionAdded, nil),
        (.verifyingContent, nil)] + jointItems.flatMap { [(.addingReviewItem, $0.key), (.reviewItemAdded, $0.key)] }
    for (phase, itemKey) in cases {
        let root = jointDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let api = JointWorkflowAPI(), service = ReleaseWorkflowService(directory: root, api: api)
        let plan = try await service.prepare(target: jointTarget(root), mode: .manual)
        _ = try await service.validate(operationID: plan.operationID, accountKey: "issuer:key")
        await api.fail(at: phase, item: itemKey)
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.submit(operationID: plan.operationID, accountKey: "issuer:key", confirmationDigest: plan.confirmationDigest)
        }
        let restarted = ReleaseWorkflowService(directory: root, api: api)
        let status = try await restarted.status(operationID: plan.operationID, accountKey: "issuer:key")
        #expect(status.resumableSubmissionID == "submission")
        #expect(await api.submits == 0)
        await api.fail(at: nil)
        let done = try await restarted.submit(operationID: plan.operationID, accountKey: "issuer:key",
            confirmationDigest: plan.confirmationDigest, resumeSubmissionID: "submission")
        #expect(done.state == .submitted)
        #expect(await api.creates == 1)
        #expect(await api.adds.count == 4)
        #expect(await api.adds.values.allSatisfy { $0 == 1 })
        #expect(await api.submits == 1)
    }
}

@Test func jointReleaseDoesNotAdoptEmptyDraftWhenCreateReplyWasLost() async throws {
    let root = jointDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = JointWorkflowAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let plan = try await service.prepare(target: jointTarget(root), mode: .manual)
    _ = try await service.validate(operationID: plan.operationID, accountKey: "issuer:key")
    await api.fail(at: nil, loseCreateReply: true)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: plan.operationID, accountKey: "issuer:key", confirmationDigest: plan.confirmationDigest)
    }
    let status = try await service.status(operationID: plan.operationID, accountKey: "issuer:key")
    #expect(status.submissionID == nil)
    #expect(status.resumableSubmissionID == nil)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: plan.operationID, accountKey: "issuer:key", confirmationDigest: plan.confirmationDigest,
                                 resumeSubmissionID: "submission")
    }
    #expect(await api.creates == 1)
    #expect(await api.submits == 0)
}

@Test func jointReleaseRejectsChangedOrMissingJournaledItemsAndChangedContent() async throws {
    for mutation in ["replace", "missing", "extra", "app", "metadata"] {
        let root = jointDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let api = JointWorkflowAPI(), service = ReleaseWorkflowService(directory: root, api: api)
        let plan = try await service.prepare(target: jointTarget(root), mode: .manual)
        _ = try await service.validate(operationID: plan.operationID, accountKey: "issuer:key")
        await api.fail(at: .reviewItemAdded, item: jointItems[0].key)
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.submit(operationID: plan.operationID, accountKey: "issuer:key", confirmationDigest: plan.confirmationDigest)
        }
        switch mutation {
        case "replace": await api.replaceItem(jointItems[0].key, with: "replacement")
        case "missing": await api.replaceItem(jointItems[0].key, with: nil)
        case "extra": await api.replaceItem("inAppPurchaseVersions:foreign", with: "foreign-item")
        case "app": await api.replaceAppItem("other-app-item")
        default: await api.changeContent()
        }
        let status = try await service.status(operationID: plan.operationID, accountKey: "issuer:key")
        #expect(status.resumableSubmissionID == nil)
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.submit(operationID: plan.operationID, accountKey: "issuer:key", confirmationDigest: plan.confirmationDigest,
                                     resumeSubmissionID: "submission")
        }
        #expect(await api.submits == 0)
    }
}

@Test func jointReleaseFinalSubmitIntentCannotBeReplayedButAcceptedResultReconciles() async throws {
    for phase in [ReleaseSubmissionPhase.submitting, .acknowledged] {
        let root = jointDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let api = JointWorkflowAPI(), service = ReleaseWorkflowService(directory: root, api: api)
        let plan = try await service.prepare(target: jointTarget(root), mode: .manual)
        _ = try await service.validate(operationID: plan.operationID, accountKey: "issuer:key")
        await api.fail(at: phase)
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.submit(operationID: plan.operationID, accountKey: "issuer:key", confirmationDigest: plan.confirmationDigest)
        }
        let status = try await service.status(operationID: plan.operationID, accountKey: "issuer:key")
        #expect(status.resumableSubmissionID == nil)
        #expect(status.state == (phase == .acknowledged ? .submitted : .submissionPending))
        if phase == .submitting {
            await #expect(throws: ReleaseWorkflowError.self) {
                try await service.submit(operationID: plan.operationID, accountKey: "issuer:key", confirmationDigest: plan.confirmationDigest,
                                         resumeSubmissionID: "submission")
            }
        }
        #expect(await api.submits == (phase == .acknowledged ? 1 : 0))
    }
}

@Test func jointReleaseSelectionCannotBeAddedToExistingConfirmation() async throws {
    let root = jointDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = JointWorkflowAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let plan = try await service.prepare(target: jointTarget(root), mode: .manual)
    let path = root.appendingPathComponent("\(plan.operationID).json")
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    var target = try #require(json["target"] as? [String: Any])
    target["reviewItems"] = [["type": "inAppPurchaseVersions", "id": "different-product"]]
    json["target"] = target
    try JSONSerialization.data(withJSONObject: json).write(to: path)
    await #expect(throws: ReleaseWorkflowError.self) { try await service.loadRecord(operationID: plan.operationID) }
    #expect(await api.creates == 0)
}

@Test func jointReleaseMissingAttemptRequiresDefinitiveRejectionBeforeRetry() async throws {
    for phase in [ReleaseSubmissionPhase.addingVersion, .addingReviewItem] {
        for httpStatus in [nil, 409, 408, 503] as [Int?] {
            let root = jointDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let api = JointWorkflowAPI(), service = ReleaseWorkflowService(directory: root, api: api)
            let plan = try await service.prepare(target: jointTarget(root), mode: .manual)
            _ = try await service.validate(operationID: plan.operationID, accountKey: "issuer:key")
            await api.fail(at: phase, item: phase == .addingReviewItem ? jointItems[0].key : nil,
                           httpStatus: httpStatus, missingAttempt: true)
            await #expect(throws: ReleaseWorkflowError.self) {
                try await service.submit(operationID: plan.operationID, accountKey: "issuer:key", confirmationDigest: plan.confirmationDigest)
            }
            let status = try await service.status(operationID: plan.operationID, accountKey: "issuer:key")
            #expect((status.resumableSubmissionID != nil) == (httpStatus == 409))
            #expect(await api.submits == 0)
            await api.fail(at: nil)
            if httpStatus == 409 {
                let done = try await service.submit(operationID: plan.operationID, accountKey: "issuer:key",
                    confirmationDigest: plan.confirmationDigest, resumeSubmissionID: "submission")
                #expect(done.state == .submitted)
                #expect(await api.adds.values.allSatisfy { $0 == 1 })
            } else {
                await #expect(throws: ReleaseWorkflowError.self) {
                    try await service.submit(operationID: plan.operationID, accountKey: "issuer:key",
                        confirmationDigest: plan.confirmationDigest, resumeSubmissionID: "submission")
                }
            }
        }
    }
}

@Test func jointReleaseSubmittedStateStillRequiresExactAuthorizedItemSet() async throws {
    for mutation in ["missing", "extra", "replaced"] {
        let root = jointDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let api = JointWorkflowAPI(), service = ReleaseWorkflowService(directory: root, api: api)
        let plan = try await service.prepare(target: jointTarget(root), mode: .manual)
        _ = try await service.validate(operationID: plan.operationID, accountKey: "issuer:key")
        await api.fail(at: .acknowledged)
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.submit(operationID: plan.operationID, accountKey: "issuer:key", confirmationDigest: plan.confirmationDigest)
        }
        if mutation == "missing" { await api.replaceItem(jointItems[0].key, with: nil) }
        if mutation == "extra" { await api.replaceItem("inAppPurchaseVersions:other", with: "foreign") }
        if mutation == "replaced" { await api.replaceItem(jointItems[0].key, with: "new-item-id") }
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.status(operationID: plan.operationID, accountKey: "issuer:key")
        }
        #expect(await api.submits == 1)
    }
}

@Test func jointReleaseAppOnlyPreparationCannotSilentlyDiscardProductSelection() async throws {
    let root = jointDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = JointWorkflowAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let plan = try await service.prepare(target: jointTarget(root), mode: .manual)
    let appOnly = jointTarget(root, items: [])
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.prepare(target: appOnly, mode: .manual, preserveReviewSelection: true)
    }
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.prepareAfterAttachingBuild(target: appOnly, mode: .manual, preserveReviewSelection: true) {
            Issue.record("Build attachment must not run after silently dropping products")
        }
    }
    #expect(try await service.activeOperation(target: appOnly)?.operationID == plan.operationID)
    #expect(await api.creates == 0)
}
