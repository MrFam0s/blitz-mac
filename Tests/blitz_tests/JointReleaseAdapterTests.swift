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
            } else if method == "PATCH", path == "/v1/reviewSubmissions/draft1" {
                if !finalReplyLost || finalRequestApplied {
                    submitted = true
                    products.setVersionState("WAITING_FOR_REVIEW")
                    items = items.map { value in var value = value; value["attributes"] = ["state": "WAITING_FOR_REVIEW"]; return value }
                }
                if finalReplyLost { throw URLError(.timedOut) }
                envelope = ["data": resource("reviewSubmissions", "draft1", [:], nil)]
            } else { throw ReleaseWorkflowAPIError.invalidResponse }
        } else if let productEnvelope = products.response(for: path) {
            envelope = productEnvelope
        } else {
            let appAttached = items.contains { ($0["relationships"] as? [String: Any])?["appStoreVersion"] != nil }
            switch url.path {
            case "/v1/apps/app1": envelope = ["data": resource("apps", "app1", ["bundleId": "org.example.App", "name": "App"], nil)]
            case "/v1/apps/app1/appStoreVersions":
                envelope = ["data": [resource("appStoreVersions", "version1", ["platform": "IOS", "versionString": "1.0", "releaseType": "MANUAL",
                    "appStoreState": submitted ? "WAITING_FOR_REVIEW" : (appAttached ? "READY_FOR_REVIEW" : "PREPARE_FOR_SUBMISSION")], nil)]]
            case "/v1/appStoreVersions/version1/build": envelope = ["data": ["id": "build8", "type": "builds"]]
            case "/v1/appStoreVersions/version1/appStoreVersionLocalizations", "/v1/apps/app1/appInfos": envelope = ["data": []]
            case "/v1/appStoreVersions/version1/appStoreReviewDetail": envelope = ["data": NSNull()]
            case "/v1/reviewSubmissions":
                envelope = ["data": draft.map { [resource("reviewSubmissions", $0,
                    ["platform": "IOS", "state": submitted ? "WAITING_FOR_REVIEW" : "READY_FOR_REVIEW"], ["app": link("apps", "app1")])] } ?? []]
            case "/v1/reviewSubmissions/draft1/items": envelope = ["data": items]
            default: throw ReleaseWorkflowAPIError.invalidResponse
            }
        }
        return .init(statusCode: 200, headers: [:], contentType: "application/json", body: try JSONSerialization.data(withJSONObject: envelope))
    }

    func writeCounts() -> (drafts: Int, items: Int, submits: Int) {
        (writes.filter { $0.0 == "POST" && $0.1 == "/v1/reviewSubmissions" }.count,
         writes.filter { $0.1 == "/v1/reviewSubmissionItems" }.count,
         writes.filter { $0.0 == "PATCH" }.count)
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
            let report: [String: Any] = ["appId": target.appID, "versionId": target.versionID, "platform": target.platform,
                "checks": [], "summary": ["blocking": 0, "warnings": 0],
                "deep": ["checks": [], "summary": ["blocked": 0, "unverified": 0]]]
            let passed = ReleaseWebEvidence.Check(status: "passed", reason: "synthetic_fixture")
            return .init(report: try JSONSerialization.data(withJSONObject: report), web: .init(appId: target.appID,
                bundleId: target.bundleID, bindingVerified: true, bindingReason: "synthetic_fixture", appleId: "fixture@example.invalid",
                providerId: "provider1", programLicense: passed, businessFree: passed, businessPaid: passed), exitCode: 0)
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
