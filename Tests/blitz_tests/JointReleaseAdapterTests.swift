import Foundation
import Testing
@testable import Blitz

private actor JointAdapterFixture {
    var products = JointProductFixture()
    var draft: String?
    var submitted = false
    var items: [[String: Any]] = []
    var writes: [(String, String, [String: Any])] = []
    var failItemKey: String?
    var loseItemReply = false
    var finalReplyLost = false
    var finalRequestApplied = false
    var alterAfterLastItem: String?
    var rejectedReview = false
    var historicalSubmittedDate = "2026-11-15T11:05:57Z"
    var secondActiveReview = false
    var alteredBuild = false
    var releaseMode = "MANUAL"
    var resolutionReplyLost = false
    var resolutionRequestApplied = false
    var mutateAfterResolution: String?

    func setMixedReviewStates(appAccepted: Bool = false) {
        let states = appAccepted ? ["ACCEPTED", "READY_FOR_REVIEW", "READY_FOR_REVIEW", "REJECTED"] : ["REJECTED", "REJECTED", "ACCEPTED", "READY_FOR_REVIEW"]
        for index in items.indices { items[index]["attributes"] = ["state": states[index]] }
        syncProductStates()
    }

    private func syncProductStates() {
        for item in items {
            guard let state = (item["attributes"] as? [String: Any])?["state"] as? String,
                  let relations = item["relationships"] as? [String: [String: Any]],
                  let selected = relations.first(where: { !["reviewSubmission", "appStoreVersion"].contains($0.key) })?.value["data"] as? [String: String],
                  let id = selected["id"] else { continue }
            let parentCatalog = selected["type"] == "inAppPurchaseVersions" ? "/v1/apps/app1/inAppPurchasesV2" :
                (selected["type"] == "subscriptionVersions" ? "/v1/subscriptionGroups/group1/subscriptions" : nil)
            if let parentCatalog {
                var parent = products.lists[parentCatalog]![0], attrs = parent["attributes"] as! [String: Any]
                attrs["state"] = state == "REJECTED" ? "REJECTED" : (["ACCEPTED", "APPROVED"].contains(state) ? "APPROVED" : "READY_TO_SUBMIT")
                parent["attributes"] = attrs; products.lists[parentCatalog]![0] = parent
            }
            for key in Array(products.singles.keys) where products.singles[key]?["id"] as? String == id {
                var value = products.singles[key]!, attrs = value["attributes"] as! [String: Any]
                attrs["state"] = state; value["attributes"] = attrs; products.singles[key] = value
            }
            for key in Array(products.lists.keys) where key.hasSuffix("/versions") {
                products.lists[key] = products.lists[key]!.map { value in
                    guard value["id"] as? String == id else { return value }
                    var value = value, attrs = value["attributes"] as! [String: Any]
                    attrs["state"] = state; value["attributes"] = attrs; return value
                }
            }
        }
    }

    func configureResolution(lost: Bool = false, applied: Bool = false, alteration: String? = nil) {
        resolutionReplyLost = lost; resolutionRequestApplied = applied; mutateAfterResolution = alteration
    }

    func currentVersionState() -> String {
        if submitted { return "WAITING_FOR_REVIEW" }
        if rejectedReview, let state = (items.first?["attributes"] as? [String: String])?["state"],
           ["REJECTED", "ACCEPTED"].contains(state) { return state }
        return items.isEmpty ? "PREPARE_FOR_SUBMISSION" : "READY_FOR_REVIEW"
    }

    func validationChecks() -> [[String: Any]] {
        guard rejectedReview else { return [] }
        var checks: [[String: Any]] = []
        if currentVersionState() == "ACCEPTED" {
            checks.append(["id": "version.state.editable", "severity": "error", "field": "appVersionState",
                           "message": "version is in non-editable state \"ACCEPTED\""])
        }
        for (path, type, checkID, prefix) in [
            ("/v1/apps/app1/inAppPurchasesV2", "inAppPurchaseV2", "iap.review_readiness.needs_attention", "IAP"),
            ("/v1/subscriptionGroups/group1/subscriptions", "subscription", "subscriptions.review_readiness.needs_attention", "Subscription")] {
            for parent in products.lists[path] ?? [] {
                let state = (parent["attributes"] as? [String: Any])?["state"] as? String ?? ""
                if ["REJECTED", "READY_TO_SUBMIT"].contains(state) {
                    checks.append(["id": checkID, "severity": "warning", "field": "state", "resourceType": type,
                                   "resourceId": parent["id"]!, "message": "\(prefix) \"Fixture\" is \(state)"])
                }
            }
        }
        return checks
    }

    func resolutionWrites() -> [String] { writes.filter { $0.0 == "PATCH" && $0.1.hasPrefix("/v1/reviewSubmissionItems/") }.map(\.1) }


    func resolveRejectedReview(alteration: String? = nil) {
        submitted = false; rejectedReview = true
        items = items.map { value in var value = value; value["attributes"] = ["state": "READY_FOR_REVIEW"]; return value }
        products.setVersionState("READY_FOR_REVIEW")
        alterResolvedReview(alteration)
    }

    func alterResolvedReview(_ alteration: String?) {
        switch alteration {
        case "rejected": items[0]["attributes"] = ["state": "REJECTED"]
        case "waiting": items[1]["attributes"] = ["state": "WAITING_FOR_REVIEW"]
        case "missing": items.removeLast()
        case "extra": items.append(JointProductFixture.resource("reviewSubmissionItems", "extra", attrs: ["state": "READY_FOR_REVIEW"],
            relationships: ["appEvent": JointProductFixture.link("appEvents", "event1")]))
        case "itemIdentity": items[0]["id"] = "replacement-app-item"
        case "productItemIdentity": items[1]["id"] = "replacement-product-item"
        case "secondReview": secondActiveReview = true
        case "noDate": historicalSubmittedDate = ""
        case "build": alteredBuild = true
        case "mode": releaseMode = "AFTER_APPROVAL"
        case "foreignSubmission": draft = "foreign"
        case "metadata":
            products.lists["/v1/inAppPurchaseVersions/iap-version/localizations"]![0]["attributes"] = ["locale": "de-DE", "name": "Changed", "description": "Changed"]
        default: break
        }
    }

    func configure(failItem: String? = nil, loseItemReply: Bool = false, finalReplyLost: Bool = false,
                   finalRequestApplied: Bool = false, alteration: String? = nil) {
        self.failItemKey = failItem; self.loseItemReply = loseItemReply
        self.finalReplyLost = finalReplyLost; self.finalRequestApplied = finalRequestApplied
        self.alterAfterLastItem = alteration
    }

    func response(_ method: String, _ path: String, _ headers: [String: String], _ body: Data?) throws -> ASCDaemonClient.HTTPResponse {
        let url = try #require(URLComponents(string: path))
        let resource = JointProductFixture.resource
        let link = JointProductFixture.link
        var envelope: [String: Any]
        if method != "GET" {
            let payload = try #require(try body.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil)
            writes.append((method, path, payload))
            if method == "POST", path == "/v1/reviewSubmissions" {
                #expect(draft == nil)
                draft = "draft1"
                envelope = ["data": resource("reviewSubmissions", "draft1", [:], nil)]
            } else if method == "POST", path == "/v1/reviewSubmissionItems" {
                let data = try #require(payload["data"] as? [String: Any])
                let relations = try #require(data["relationships"] as? [String: [String: Any]])
                let content = try #require(relations.first { $0.key != "reviewSubmission" })
                let selected = try #require(content.value["data"] as? [String: String])
                let key = "\(selected["type"]!):\(selected["id"]!)"
                if failItemKey == key && !loseItemReply {
                    return .init(statusCode: 409, headers: [:], contentType: "application/json",
                        body: try JSONSerialization.data(withJSONObject: ["errors": [["code": "ENTITY_ERROR.ATTRIBUTE.INVALID"]]]))
                }
                #expect(!items.contains { (($0["relationships"] as? [String: [String: Any]])?[content.key]?["data"] as? [String: String]) == selected })
                let id = "item-\(selected["id"]!)"
                items.append(resource("reviewSubmissionItems", id, ["state": "READY_FOR_REVIEW"], relations))
                products.setVersionState("READY_FOR_REVIEW")
                if items.count == 4 {
                    switch alterAfterLastItem {
                    case "identity": items[1]["id"] = "replacement-item"
                    case "extra": items.append(resource("reviewSubmissionItems", "extra", ["state": "READY_FOR_REVIEW"],
                        ["appEvent": link("appEvents", "event1")]))
                    case "metadata": products.lists["/v1/inAppPurchaseVersions/iap-version/localizations"]![0]["attributes"] = ["locale": "de-DE", "name": "Changed", "description": "Changed"]
                    case "media":
                        var shot = products.singles["/v2/inAppPurchases/iap1/appStoreReviewScreenshot"]!
                        var attrs = shot["attributes"] as! [String: Any]
                        attrs["assetDeliveryState"] = ["state": "FAILED"]
                        shot["attributes"] = attrs
                        products.singles["/v2/inAppPurchases/iap1/appStoreReviewScreenshot"] = shot
                    default: break
                    }
                }
                if failItemKey == key && loseItemReply { throw URLError(.timedOut) }
                envelope = ["data": resource("reviewSubmissionItems", id, [:], nil)]
            } else if method == "PATCH", path.hasPrefix("/v1/reviewSubmissionItems/") {
                let id = String(path.split(separator: "/").last!)
                let index = try #require(items.firstIndex { $0["id"] as? String == id })
                let data = try #require(payload["data"] as? [String: Any])
                #expect(data["id"] as? String == id && data["type"] as? String == "reviewSubmissionItems")
                let attributes = try #require(data["attributes"] as? [String: Bool])
                #expect(attributes == ["resolved": true])
                #expect((items[index]["attributes"] as? [String: Any])?["state"] as? String == "REJECTED")
                if !resolutionReplyLost || resolutionRequestApplied {
                    items[index]["attributes"] = ["state": "READY_FOR_REVIEW"]
                    syncProductStates()
                }
                if let mutateAfterResolution { alterResolvedReview(mutateAfterResolution) }
                if resolutionReplyLost { throw URLError(.timedOut) }
                envelope = ["data": items[index]]
            } else if method == "PATCH", path == "/v1/reviewSubmissions/draft1" {
                if !finalReplyLost || finalRequestApplied {
                    submitted = true; rejectedReview = false
                    products.setVersionState("WAITING_FOR_REVIEW")
                    // Item state stays READY_FOR_REVIEW/ACCEPTED; queue status belongs to the submission.
                }
                if finalReplyLost { throw URLError(.timedOut) }
                envelope = ["data": resource("reviewSubmissions", "draft1", [:], nil)]
            } else { throw ReleaseWorkflowAPIError.invalidResponse }
        } else if let productEnvelope = products.response(for: path) {
            envelope = productEnvelope
        } else {
            switch url.path {
            case "/v1/apps/app1": envelope = ["data": resource("apps", "app1", ["bundleId": "org.example.App", "name": "App"], nil)]
            case "/v1/apps/app1/appStoreVersions":
                envelope = ["data": [resource("appStoreVersions", "version1", ["platform": "IOS", "versionString": "1.0", "releaseType": releaseMode,
                    "appStoreState": currentVersionState()], nil)]]
            case "/v1/appStoreVersions/version1/build": envelope = ["data": ["id": alteredBuild ? "otherBuild" : "build8", "type": "builds"]]
            case "/v1/appStoreVersions/version1/appStoreVersionLocalizations", "/v1/apps/app1/appInfos": envelope = ["data": []]
            case "/v1/appStoreVersions/version1/appStoreReviewDetail": envelope = ["data": NSNull()]
            case "/v1/reviewSubmissions":
                envelope = ["data": draft.map { [resource("reviewSubmissions", $0,
                    ["platform": "IOS", "state": rejectedReview ? "UNRESOLVED_ISSUES" : (submitted ? "WAITING_FOR_REVIEW" : "READY_FOR_REVIEW"),
                     "submittedDate": rejectedReview ? historicalSubmittedDate : ""], ["app": link("apps", "app1")])] } ?? []]
                if secondActiveReview {
                    var reviews = envelope["data"] as! [[String: Any]]
                    reviews.append(resource("reviewSubmissions", "second", ["platform": "IOS", "state": "READY_FOR_REVIEW"], ["app": link("apps", "app1")]))
                    envelope["data"] = reviews
                }
            case "/v1/reviewSubmissions/draft1/items", "/v1/reviewSubmissions/foreign/items": envelope = ["data": items]
            case "/v1/reviewSubmissions/second/items": envelope = ["data": []]
            default: throw ReleaseWorkflowAPIError.invalidResponse
            }
        }
        return .init(statusCode: 200, headers: [:], contentType: "application/json", body: try JSONSerialization.data(withJSONObject: envelope))
    }

    func writeCounts() -> (drafts: Int, items: Int, submits: Int) {
        (writes.filter { $0.0 == "POST" && $0.1 == "/v1/reviewSubmissions" }.count,
         writes.filter { $0.1 == "/v1/reviewSubmissionItems" }.count,
         writes.filter { $0.0 == "PATCH" && $0.1 == "/v1/reviewSubmissions/draft1" }.count)
    }
}

private func jointAdapter(_ fixture: JointAdapterFixture) -> ReleaseWorkflowASCAdapter {
    .init(accountKey: "issuer:key", transport: { try await fixture.response($0, $1, $2, $3) },
        cli: { _ in throw ReleaseWorkflowAPIError.validationUnavailable }, loadBuild: { id in
            var build = ASCBuild(id: id, attributes: .init(version: "8", uploadedDate: nil, processingState: "VALID",
                expirationDate: nil, expired: false, minOsVersion: nil, iconAssetToken: nil))
            build.relationships = .init(app: .init(data: .init(id: "app1")), preReleaseVersion: .init(data: .init(id: "pre1")))
            build.preReleaseVersion = .init(id: "pre1", attributes: .init(version: "1.0", platform: "IOS"))
            return build
        }, readinessReport: { target in
            let checks = await fixture.validationChecks()
            let report: [String: Any] = ["appId": target.appID, "versionId": target.versionID, "platform": target.platform,
                "checks": checks, "summary": ["blocking": checks.count, "warnings": checks.filter { $0["severity"] as? String == "warning" }.count],
                "deep": ["checks": [], "summary": ["blocked": 0, "unverified": 0]]]
            let passed = ReleaseWebEvidence.Check(status: "passed", reason: "synthetic_fixture")
            return .init(report: try JSONSerialization.data(withJSONObject: report), web: .init(appId: target.appID,
                bundleId: target.bundleID, bindingVerified: true, bindingReason: "synthetic_fixture", appleId: "fixture@example.invalid",
                providerId: "provider1", programLicense: passed, businessFree: passed, businessPaid: passed), exitCode: checks.isEmpty ? 0 : 1)
        })
}

private func jointAdapterPrepared(_ fixture: JointAdapterFixture, root: URL) async throws -> (ReleaseWorkflowService, ReleaseWorkflowRecord) {
    let service = ReleaseWorkflowService(directory: root, api: jointAdapter(fixture))
    let record = try await service.prepare(target: JointProductFixture().target(), mode: .manual)
    let validated = try await service.validate(operationID: record.operationID, accountKey: record.target.accountKey)
    #expect(validated.validation?.ready == true)
    return (service, validated)
}

@Test func jointAdapterSubmitsExactlyAppPurchaseGroupSubscriptionOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = JointAdapterFixture()
    let (service, record) = try await jointAdapterPrepared(fixture, root: root)
    #expect(await fixture.writeCounts().drafts == 0)
    let done = try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey, confirmationDigest: record.confirmationDigest)
    #expect(done.state == .submitted && done.reviewItemIDs?.count == 3)
    _ = try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey, confirmationDigest: record.confirmationDigest)
    let counts = await fixture.writeCounts()
    #expect(counts.drafts == 1 && counts.items == 4 && counts.submits == 1)
}

@Test func jointAdapterReconcilesLostItemReplyWithoutDuplicateProductOrDraft() async throws {
    for item in JointProductFixture.allItems {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = JointAdapterFixture()
        let (service, record) = try await jointAdapterPrepared(fixture, root: root)
        await fixture.configure(failItem: item.key, loseItemReply: true)
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey, confirmationDigest: record.confirmationDigest)
        }
        let restarted = ReleaseWorkflowService(directory: root, api: jointAdapter(fixture))
        let status = try await restarted.status(operationID: record.operationID, accountKey: record.target.accountKey)
        #expect(status.resumableSubmissionID == "draft1")
        await fixture.configure()
        let done = try await restarted.submit(operationID: record.operationID, accountKey: record.target.accountKey,
            confirmationDigest: record.confirmationDigest, resumeSubmissionID: "draft1")
        #expect(done.state == .submitted)
        let counts = await fixture.writeCounts()
        #expect(counts.drafts == 1 && counts.items == 4 && counts.submits == 1)
    }
}

@Test func jointAdapterRejectsChangedSelectionIDsMetadataAndMediaBeforeFinalSubmit() async throws {
    for alteration in ["identity", "extra", "metadata", "media"] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = JointAdapterFixture()
        let (service, record) = try await jointAdapterPrepared(fixture, root: root)
        await fixture.configure(alteration: alteration)
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey, confirmationDigest: record.confirmationDigest)
        }
        #expect(await fixture.writeCounts().submits == 0)
    }
}

@Test func jointAdapterUnknownFinalResponseIsReconciledNeverResent() async throws {
    for applied in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = JointAdapterFixture()
        let (service, record) = try await jointAdapterPrepared(fixture, root: root)
        await fixture.configure(finalReplyLost: true, finalRequestApplied: applied)
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey, confirmationDigest: record.confirmationDigest)
        }
        let status = try await service.status(operationID: record.operationID, accountKey: record.target.accountKey)
        #expect(status.state == (applied ? .submitted : .submissionPending))
        #expect(status.resumableSubmissionID == nil)
        if !applied {
            await #expect(throws: ReleaseWorkflowError.self) {
                try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
                    confirmationDigest: record.confirmationDigest, resumeSubmissionID: "draft1")
            }
        }
        #expect(await fixture.writeCounts().submits == 1)
    }
}


private func rejectedJointReview(_ fixture: JointAdapterFixture, root: URL) async throws -> (ReleaseWorkflowService, ReleaseWorkflowRecord) {
    let (service, prepared) = try await jointAdapterPrepared(fixture, root: root)
    let submitted = try await service.submit(operationID: prepared.operationID, accountKey: prepared.target.accountKey,
        confirmationDigest: prepared.confirmationDigest)
    await fixture.resolveRejectedReview()
    return (service, submitted)
}

@Test func jointResubmissionUsesNewFingerprintAndOnlyPatchesExactExistingReview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = JointAdapterFixture()
    let (service, old) = try await rejectedJointReview(fixture, root: root)
    let historical = try await service.loadRecord(operationID: old.operationID)
    await fixture.alterResolvedReview("metadata")
    let status = try await service.status(operationID: old.operationID, accountKey: old.target.accountKey)
    #expect(status.state == .submitted && status.submissionState == "UNRESOLVED_ISSUES")
    #expect(status.resubmittableSubmissionID == "draft1" && status.resumableSubmissionID == nil)
    // Calling old submit is read-only and exposes the actual review status.
    let oldResult = try await service.submit(operationID: old.operationID, accountKey: old.target.accountKey,
        confirmationDigest: old.confirmationDigest)
    #expect(oldResult.submissionState == "UNRESOLVED_ISSUES")
    #expect(await fixture.writeCounts().submits == 1)
    let plan = try await service.prepareResubmission(operationID: old.operationID, accountKey: old.target.accountKey, submissionID: "draft1")
    #expect(plan.operationID != old.operationID && plan.confirmationDigest != old.confirmationDigest)
    #expect(plan.contentDigest != old.contentDigest && plan.target == old.target && plan.mode == .manual)
    #expect(plan.resubmission?.previousOperationID == old.operationID)
    #expect(plan.submissionID == old.submissionID && plan.reviewItemIDs == old.reviewItemIDs)
    let same = try await service.prepareResubmission(operationID: old.operationID, accountKey: old.target.accountKey, submissionID: "draft1")
    #expect(same.operationID == plan.operationID)
    let savedOld = try await service.loadRecord(operationID: old.operationID)
    #expect(savedOld.confirmationDigest == historical.confirmationDigest && savedOld.contentDigest == historical.contentDigest)
    _ = try await service.validate(operationID: plan.operationID, accountKey: plan.target.accountKey)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: plan.operationID, accountKey: plan.target.accountKey, confirmationDigest: old.confirmationDigest)
    }
    let result = try await service.submit(operationID: plan.operationID, accountKey: plan.target.accountKey, confirmationDigest: plan.confirmationDigest)
    #expect(result.state == .submitted && result.submissionState == "WAITING_FOR_REVIEW")
    #expect(result.submissionProgress?.phase == .acknowledged)
    _ = try await service.submit(operationID: plan.operationID, accountKey: plan.target.accountKey, confirmationDigest: plan.confirmationDigest)
    let counts = await fixture.writeCounts()
    #expect(counts.drafts == 1 && counts.items == 4 && counts.submits == 2)
}

@Test func jointResubmissionRefusesIncompleteForeignUnresolvedOrChangedIdentities() async throws {
    for alteration in ["rejected", "waiting", "missing", "extra", "itemIdentity", "productItemIdentity", "secondReview", "noDate", "build", "mode", "foreignSubmission"] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = JointAdapterFixture()
        let (service, old) = try await rejectedJointReview(fixture, root: root)
        await fixture.alterResolvedReview(alteration)
        await #expect(throws: (any Error).self) {
            try await service.prepareResubmission(operationID: old.operationID, accountKey: old.target.accountKey, submissionID: "draft1")
        }
        #expect(await fixture.writeCounts().submits == 1)
    }
}

@Test func jointResubmissionRejectsChangedMetadataAfterPreparationAndOldOrForeignIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = JointAdapterFixture()
    let (service, old) = try await rejectedJointReview(fixture, root: root)
    for (account, id) in [("wrong:key", "draft1"), (old.target.accountKey, "foreign")] {
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.prepareResubmission(operationID: old.operationID, accountKey: account, submissionID: id)
        }
    }
    let plan = try await service.prepareResubmission(operationID: old.operationID, accountKey: old.target.accountKey, submissionID: "draft1")
    _ = try await service.validate(operationID: plan.operationID, accountKey: plan.target.accountKey)
    await fixture.alterResolvedReview("metadata")
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: plan.operationID, accountKey: plan.target.accountKey, confirmationDigest: plan.confirmationDigest)
    }
    #expect(await fixture.writeCounts().submits == 1)
}

@Test func jointResubmissionUnknownFinalRequestCannotBeRetriedOrReprepared() async throws {
    for applied in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = JointAdapterFixture()
        let (service, old) = try await rejectedJointReview(fixture, root: root)
        let plan = try await service.prepareResubmission(operationID: old.operationID, accountKey: old.target.accountKey, submissionID: "draft1")
        _ = try await service.validate(operationID: plan.operationID, accountKey: plan.target.accountKey)
        await fixture.configure(finalReplyLost: true, finalRequestApplied: applied)
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.submit(operationID: plan.operationID, accountKey: plan.target.accountKey, confirmationDigest: plan.confirmationDigest)
        }
        let restarted = ReleaseWorkflowService(directory: root, api: jointAdapter(fixture))
        let status = try await restarted.status(operationID: plan.operationID, accountKey: plan.target.accountKey)
        #expect(status.state == (applied ? .submitted : .submissionPending))
        #expect(status.resumableSubmissionID == nil && status.resubmittableSubmissionID == nil)
        if !applied {
            await #expect(throws: ReleaseWorkflowError.self) {
                try await restarted.submit(operationID: plan.operationID, accountKey: plan.target.accountKey,
                    confirmationDigest: plan.confirmationDigest, resumeSubmissionID: "draft1")
            }
        }
        for source in [old.operationID, plan.operationID] {
            await #expect(throws: ReleaseWorkflowError.self) {
                try await restarted.prepareResubmission(operationID: source, accountKey: old.target.accountKey, submissionID: "draft1")
            }
        }
        #expect(await fixture.writeCounts().submits == 2)
    }
}

@Test func jointResubmissionAdapterRechecksExactReadyContentsBeforeAnyWrite() async throws {
    for alteration in ["metadata", "rejected", "waiting", "missing", "extra", "itemIdentity", "secondReview", "build", "mode"] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = JointAdapterFixture()
        let (service, old) = try await rejectedJointReview(fixture, root: root)
        let plan = try await service.prepareResubmission(operationID: old.operationID, accountKey: old.target.accountKey, submissionID: "draft1")
        let binding = try #require(plan.resubmission)
        await fixture.alterResolvedReview(alteration)
        await #expect(throws: (any Error).self) {
            try await jointAdapter(fixture).resubmit(plan.target, binding: binding, expectedContentDigest: plan.contentDigest,
                expectedFingerprintVersion: plan.contentFingerprintVersion, expectedReleaseMode: plan.mode) { _ in }
        }
        #expect(await fixture.writeCounts().submits == 1)
    }
}


@Test func jointResolutionRequiresNewExplicitPlanAndPreservesAcceptedSiblings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = JointAdapterFixture()
    let (service, old) = try await rejectedJointReview(fixture, root: root)
    await fixture.setMixedReviewStates()
    let status = try await service.status(operationID: old.operationID, accountKey: old.target.accountKey)
    #expect(status.state == .submitted && status.reviewOutcome == "issuesUnresolved")
    #expect(status.nextAction == "resolveReviewIssues" && status.resolvableSubmissionID == "draft1")
    #expect(status.resubmittableSubmissionID == nil)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.prepareResubmission(operationID: old.operationID, accountKey: old.target.accountKey, submissionID: "draft1")
    }
    let plan = try await service.prepareResubmission(operationID: old.operationID, accountKey: old.target.accountKey,
        submissionID: "draft1", resolveRejectedItems: true)
    #expect(plan.resubmission?.itemIDsToResolve?.count == 2)
    #expect(await fixture.resolutionWrites().isEmpty)
    _ = try await service.validate(operationID: plan.operationID, accountKey: plan.target.accountKey)
    let done = try await service.submit(operationID: plan.operationID, accountKey: plan.target.accountKey, confirmationDigest: plan.confirmationDigest)
    #expect(done.state == .submitted && done.reviewOutcome == "submitted")
    #expect(done.submissionState == "WAITING_FOR_REVIEW")
    let resolved = await fixture.resolutionWrites()
    #expect(Set(resolved) == Set((plan.resubmission?.itemIDsToResolve ?? []).map { "/v1/reviewSubmissionItems/\($0)" }))
    let counts = await fixture.writeCounts()
    #expect(counts.drafts == 1 && counts.items == 4 && counts.submits == 2)
}

@Test func jointResolutionStopsOnChangedContentOrIdentityBeforeFinalSubmit() async throws {
    for alteration in ["metadata", "missing", "extra", "itemIdentity", "productItemIdentity", "secondReview", "build", "mode"] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = JointAdapterFixture()
        let (service, old) = try await rejectedJointReview(fixture, root: root)
        await fixture.setMixedReviewStates()
        let plan = try await service.prepareResubmission(operationID: old.operationID, accountKey: old.target.accountKey,
            submissionID: "draft1", resolveRejectedItems: true)
        _ = try await service.validate(operationID: plan.operationID, accountKey: plan.target.accountKey)
        await fixture.configureResolution(alteration: alteration)
        await #expect(throws: (any Error).self) {
            try await service.submit(operationID: plan.operationID, accountKey: plan.target.accountKey, confirmationDigest: plan.confirmationDigest)
        }
        #expect(await fixture.resolutionWrites().count == 1)
        #expect(await fixture.writeCounts().submits == 1)
    }
}

@Test func jointResolutionLostReplyOnlyContinuesAfterReadProvesAppliedAndNeverDuplicatesWrite() async throws {
    for applied in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = JointAdapterFixture()
        let (service, old) = try await rejectedJointReview(fixture, root: root)
        await fixture.setMixedReviewStates()
        let plan = try await service.prepareResubmission(operationID: old.operationID, accountKey: old.target.accountKey,
            submissionID: "draft1", resolveRejectedItems: true)
        _ = try await service.validate(operationID: plan.operationID, accountKey: plan.target.accountKey)
        await fixture.configureResolution(lost: true, applied: applied)
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.submit(operationID: plan.operationID, accountKey: plan.target.accountKey, confirmationDigest: plan.confirmationDigest)
        }
        let restarted = ReleaseWorkflowService(directory: root, api: jointAdapter(fixture))
        let status = try await restarted.status(operationID: plan.operationID, accountKey: plan.target.accountKey)
        #expect(status.resumableResubmissionID == (applied ? "draft1" : nil))
        #expect(status.resumableSubmissionID == nil)
        await fixture.configureResolution()
        if applied {
            let done = try await restarted.submit(operationID: plan.operationID, accountKey: plan.target.accountKey,
                confirmationDigest: plan.confirmationDigest, resumeSubmissionID: "draft1")
            #expect(done.state == .submitted)
            let writes = await fixture.resolutionWrites()
            #expect(writes.count == 2 && Set(writes).count == 2)
        } else {
            await #expect(throws: ReleaseWorkflowError.self) {
                try await restarted.submit(operationID: plan.operationID, accountKey: plan.target.accountKey,
                    confirmationDigest: plan.confirmationDigest, resumeSubmissionID: "draft1")
            }
            #expect(await fixture.resolutionWrites().count == 1)
        }
    }
}


@Test func jointResolutionRetainsAcceptedAppWhileResolvingSubscriptionAndUsesRealStateFindings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = JointAdapterFixture()
    let (service, old) = try await rejectedJointReview(fixture, root: root)
    await fixture.setMixedReviewStates(appAccepted: true)
    let status = try await service.status(operationID: old.operationID, accountKey: old.target.accountKey)
    #expect(status.appleState == "ACCEPTED" && status.reviewOutcome == "issuesUnresolved")
    #expect(status.resolvableSubmissionID == "draft1")
    let plan = try await service.prepareResubmission(operationID: old.operationID, accountKey: old.target.accountKey,
        submissionID: "draft1", resolveRejectedItems: true)
    let ordinary = try await jointAdapter(fixture).readiness(plan.target)
    #expect(!ordinary.ready)
    let checked = try await service.validate(operationID: plan.operationID, accountKey: plan.target.accountKey)
    #expect(checked.validation?.ready == true)
    #expect(checked.validation?.diagnostics?.contains { $0.reason == "accepted_app_item_retained_in_exact_resubmission" } == true)
    #expect(checked.validation?.diagnostics?.contains { $0.reason == "retained_product_state_verified_for_explicit_resubmission" } == true)
    let done = try await service.submit(operationID: plan.operationID, accountKey: plan.target.accountKey, confirmationDigest: plan.confirmationDigest)
    #expect(done.reviewOutcome == "submitted")
    #expect(await fixture.resolutionWrites() == ["/v1/reviewSubmissionItems/item-sub-version"])
    #expect(await fixture.writeCounts().drafts == 1)
}
