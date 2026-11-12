import Foundation
import Testing
@testable import Blitz

private func workflowTarget(_ root: URL, app: String = "app1", build: String = "build1") -> ReleaseWorkflowTarget {
    ReleaseWorkflowTarget(projectID: "project1", projectPath: root.resolvingSymlinksInPath().path,
        appID: app, bundleID: "org.example.App", platform: "IOS", accountKey: "issuer:key",
        versionID: "version1", buildID: build)
}

private func workflowSnapshot(app: String = "app1", build: String = "build1", attached: String? = "build1",
                              content: String = "content-a", state: String = "PREPARE_FOR_SUBMISSION",
                              mode: String = "MANUAL", valid: Bool = true) -> ReleaseWorkflowSnapshot {
    ReleaseWorkflowSnapshot(appID: app, bundleID: "org.example.App", versionID: "version1", platform: "IOS",
        versionString: "1.2", buildID: build, buildNumber: "12", buildValid: valid,
        attachedBuildID: attached, appleState: state, releaseType: mode, contentDigest: content,
        submissionID: state == "WAITING_FOR_REVIEW" ? "submission1" : nil,
        submissionState: state == "WAITING_FOR_REVIEW" ? "WAITING_FOR_REVIEW" : nil)
}

private actor WorkflowMockAPI: ReleaseWorkflowAPI {
    nonisolated let accountKey = "issuer:key"
    var value = workflowSnapshot()
    var report = ReleaseWorkflowValidation(ready: true, blocking: 0, warnings: 0, unverified: 0, checkIDs: ["metadata.required"])
    var readinessFails = false
    var submitFails = false
    var modeFails = false
    var submissions = 0
    var modeWrites = 0
    var snapshotReads = 0
    var pause = false
    private var snapshotWaiter: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?

    func configure(value: ReleaseWorkflowSnapshot? = nil, readinessFails: Bool? = nil,
                   submitFails: Bool? = nil, modeFails: Bool? = nil, report: ReleaseWorkflowValidation? = nil) {
        if let value { self.value = value }
        if let readinessFails { self.readinessFails = readinessFails }
        if let submitFails { self.submitFails = submitFails }
        if let modeFails { self.modeFails = modeFails }
        if let report { self.report = report }
    }
    func pauseNextSnapshot() { pause = true }
    func waitUntilPaused() async {
        if snapshotWaiter != nil { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func resumeSnapshot() { snapshotWaiter?.resume(); snapshotWaiter = nil }
    func snapshot(_ target: ReleaseWorkflowTarget) async throws -> ReleaseWorkflowSnapshot {
        snapshotReads += 1
        if pause {
            pause = false
            await withCheckedContinuation { continuation in
                snapshotWaiter = continuation
                enteredWaiter?.resume(); enteredWaiter = nil
            }
        }
        return value
    }
    func readiness(_ target: ReleaseWorkflowTarget) async throws -> ReleaseWorkflowValidation {
        if readinessFails { throw ReleaseWorkflowAPIError.httpStatus(401) }
        return report
    }
    func setReleaseMode(_ mode: ReleaseWorkflowMode, target: ReleaseWorkflowTarget) async throws {
        modeWrites += 1
        value = workflowSnapshot(mode: mode.rawValue)
        if modeFails { throw ReleaseWorkflowAPIError.httpStatus(503) }
    }
    func submit(_ target: ReleaseWorkflowTarget, expectedContentDigest: String, expectedFingerprintVersion: Int?, expectedReleaseMode: ReleaseWorkflowMode, resumingSubmissionID: String?,
                progress: @escaping @Sendable (ReleaseSubmissionProgress) async throws -> Void) async throws -> String? {
        submissions += 1
        try await progress(.init(phase: .submitting, submissionID: "submission1"))
        if submitFails { throw ReleaseWorkflowAPIError.httpStatus(503) }
        value = workflowSnapshot(state: "WAITING_FOR_REVIEW", mode: value.releaseType ?? "MANUAL")
        try await progress(.init(phase: .acknowledged, submissionID: "submission1"))
        return "submission1"
    }
}

private func workflowDirectory() -> URL {
    FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("blitz-workflow-\(UUID().uuidString)")
}

@Test func releaseWorkflowUsesFixedTargetAndRequiresFreshValidationAndConfirmation() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let prepared = try await service.prepare(target: workflowTarget(root), mode: .automaticAfterApproval)
    #expect(prepared.state == .prepared)
    #expect(await api.submissions == 0)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: prepared.operationID, accountKey: "issuer:key", confirmationDigest: prepared.confirmationDigest)
    }
    let checked = try await service.validate(operationID: prepared.operationID, accountKey: "issuer:key")
    #expect(checked.state == .validated)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: prepared.operationID, accountKey: "issuer:key", confirmationDigest: "wrong")
    }
    let result = try await service.submit(operationID: prepared.operationID, accountKey: "issuer:key", confirmationDigest: prepared.confirmationDigest)
    #expect(result.state == .submitted)
    #expect(result.appleState == "WAITING_FOR_REVIEW")
    #expect(result.submissionID == "submission1")
    #expect(await api.submissions == 1)
    #expect(await api.modeWrites == 1)
    _ = try await service.submit(operationID: prepared.operationID, accountKey: "issuer:key", confirmationDigest: prepared.confirmationDigest)
    #expect(await api.submissions == 1)
}

@Test func releaseWorkflowRefusesWrongAppBuildAndMissingAttachment() async throws {
    for snapshot in [workflowSnapshot(app: "other"), workflowSnapshot(build: "other"),
                     workflowSnapshot(attached: nil), workflowSnapshot(valid: false)] {
        let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let api = WorkflowMockAPI(); await api.configure(value: snapshot)
        let service = ReleaseWorkflowService(directory: root, api: api)
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.prepare(target: workflowTarget(root), mode: .manual)
        }
        #expect(await api.submissions == 0)
    }
}

@Test func releaseWorkflowRejectsAccountBeforeReadAndKeepsStablePrepareID() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let first = try await service.prepare(target: workflowTarget(root), mode: .manual)
    let second = try await service.prepare(target: workflowTarget(root), mode: .manual)
    #expect(first.operationID == second.operationID)
    let reads = await api.snapshotReads
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.status(operationID: first.operationID, accountKey: "other:key")
    }
    #expect(await api.snapshotReads == reads)
}

@Test func releaseWorkflowChangedContentInvalidatesPriorConfirmation() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let first = try await service.prepare(target: workflowTarget(root), mode: .manual)
    _ = try await service.validate(operationID: first.operationID, accountKey: "issuer:key")
    await api.configure(value: workflowSnapshot(content: "edited-screenshots"))
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: first.operationID, accountKey: "issuer:key", confirmationDigest: first.confirmationDigest)
    }
    #expect(await api.submissions == 0)
    let next = try await service.prepare(target: workflowTarget(root), mode: .manual)
    #expect(next.operationID != first.operationID)
    #expect(next.confirmationDigest != first.confirmationDigest)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.validate(operationID: first.operationID, accountKey: "issuer:key")
    }
}

@Test func releaseWorkflowReadOnlyAuthenticationFailureCanContinueAfterLogin() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    await api.configure(readinessFails: true)
    await #expect(throws: ReleaseWorkflowAPIError.self) {
        try await service.validate(operationID: record.operationID, accountKey: "issuer:key")
    }
    #expect(await api.submissions == 0)
    await api.configure(readinessFails: false)
    let restarted = ReleaseWorkflowService(directory: root, api: api)
    let resumed = try await restarted.validate(operationID: record.operationID, accountKey: "issuer:key")
    #expect(resumed.operationID == record.operationID)
    #expect(resumed.state == .validated)
}

@Test func releaseWorkflowUnknownSubmissionSurvivesRestartAndCannotBeBypassedByPrepare() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    _ = try await service.validate(operationID: record.operationID, accountKey: "issuer:key")
    await api.configure(submitFails: true)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: "issuer:key", confirmationDigest: record.confirmationDigest)
    }
    let restarted = ReleaseWorkflowService(directory: root, api: api)
    let status = try await restarted.status(operationID: record.operationID, accountKey: "issuer:key")
    #expect(status.state == .submissionPending)
    for changed in [workflowTarget(root), workflowTarget(root, build: "build2")] {
        await #expect(throws: ReleaseWorkflowError.self) { try await restarted.prepare(target: changed, mode: .manual) }
    }
    await #expect(throws: ReleaseWorkflowError.self) {
        try await restarted.submit(operationID: record.operationID, accountKey: "issuer:key", confirmationDigest: record.confirmationDigest)
    }
    #expect(await api.submissions == 1)
    await api.configure(value: workflowSnapshot(state: "WAITING_FOR_REVIEW"))
    let reconciled = try await restarted.status(operationID: record.operationID, accountKey: "issuer:key")
    #expect(reconciled.state == .submitted)
    #expect(await api.submissions == 1)
}

@Test func releaseWorkflowReconcilesUncertainReleaseModeWithoutRepeatingWrite() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let record = try await service.prepare(target: workflowTarget(root), mode: .automaticAfterApproval)
    _ = try await service.validate(operationID: record.operationID, accountKey: "issuer:key")
    await api.configure(modeFails: true)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: "issuer:key", confirmationDigest: record.confirmationDigest)
    }
    #expect(await api.submissions == 0)
    let status = try await service.status(operationID: record.operationID, accountKey: "issuer:key")
    #expect(status.state == .prepared)
    _ = try await service.validate(operationID: record.operationID, accountKey: "issuer:key")
    _ = try await service.submit(operationID: record.operationID, accountKey: "issuer:key", confirmationDigest: record.confirmationDigest)
    #expect(await api.modeWrites == 1)
    #expect(await api.submissions == 1)
}

@Test func releaseWorkflowUnverifiedReadinessBlocksSubmission() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    await api.configure(report: ReleaseWorkflowValidation(ready: false, blocking: 0, warnings: 0, unverified: 1, checkIDs: ["privacy.unverified"]))
    let checked = try await service.validate(operationID: record.operationID, accountKey: "issuer:key")
    #expect(checked.state == .prepared)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: "issuer:key", confirmationDigest: record.confirmationDigest)
    }
    #expect(await api.submissions == 0)
}

@Test func releaseWorkflowSerializesAcrossServiceInstances() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI()
    let a = ReleaseWorkflowService(directory: root, api: api), b = ReleaseWorkflowService(directory: root, api: api)
    await api.pauseNextSnapshot()
    let task = Task { try await a.prepare(target: workflowTarget(root), mode: .manual) }
    await api.waitUntilPaused()
    await #expect(throws: ReleaseWorkflowError.self) { try await b.prepare(target: workflowTarget(root), mode: .manual) }
    await api.resumeSnapshot()
    _ = try await task.value
    #expect(await api.submissions == 0)
}

@Test func releaseWorkflowJournalUsesPublicIDKeysAndRejectsSymlink() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    let data = try Data(contentsOf: root.appendingPathComponent("\(record.operationID).json"))
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["operationId"] as? String == record.operationID)
    #expect((json["target"] as? [String: Any])?["buildId"] as? String == "build1")
    #expect(!String(decoding: data, as: UTF8.self).contains("demoAccountPassword"))
    let link = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    let unsafe = ReleaseWorkflowService(directory: link, api: api)
    await #expect(throws: ReleaseWorkflowError.self) { try await unsafe.prepare(target: workflowTarget(root), mode: .manual) }
}

@Test func releaseWorkflowAdapterUsesExplicitReadinessScopeAndRejectsUnverifiedDeepChecks() async throws {
    let target = workflowTarget(workflowDirectory())
    for count in [0, 1] {
        let fixture = WorkflowSnapshotFixture()
        let adapter = ReleaseWorkflowASCAdapter(accountKey: "issuer:key", transport: { try await fixture.response($0,$1,$2,$3) },
            cli: { _ in throw ReleaseWorkflowAPIError.invalidResponse },
            loadBuild: { _ in throw ReleaseWorkflowAPIError.invalidResponse }, readinessReport: { requested in
                #expect(requested == target)
                let web = ReleaseWebEvidence(appId: target.appID, bundleId: target.bundleID, bindingVerified: true,
                    bindingReason: "fixture", appleId: "fixture@example.invalid", providerId: "PROVIDER",
                    programLicense: .init(status: count == 0 ? "passed" : "unverified", reason: "fixture"),
                    businessFree: .init(status: "passed", reason: "fixture"), businessPaid: .init(status: "passed", reason: "fixture"))
                return ReleaseReadinessPayload(report: Data("""
                {"appId":"app1","versionId":"version1","platform":"IOS","summary":{"blocking":0,"warnings":0},"deep":{"summary":{"blocked":0,"unverified":0},"checks":[]},"checks":[]}
                """.utf8), web: web, exitCode: 0)
            })
        let report = try await adapter.readiness(target)
        #expect(report.ready == (count == 0))
    }
}

@Test func releaseWorkflowAdapterRejectsDifferentValidationTargetAndUnknownOutput() async throws {
    for output in ["{}", "{\"appId\":\"other\",\"versionId\":\"version1\"}", "not json"] {
        let adapter = ReleaseWorkflowASCAdapter(accountKey: "issuer:key", transport: { _, _, _, _ in throw ReleaseWorkflowAPIError.invalidResponse },
            cli: { _ in (0, output, "") }, loadBuild: { _ in throw ReleaseWorkflowAPIError.invalidResponse })
        await #expect(throws: ReleaseWorkflowAPIError.self) { try await adapter.readiness(workflowTarget(workflowDirectory())) }
    }
}

private actor WorkflowSnapshotFixture {
    var reversedScreenshots = false
    var changedText = false
    var foreignPage = false
    var existingSubmission = false
    var editAfterItem = false
    var createdDraft = false
    var addedVersion = false
    var submitted = false
    var completedHistory = false
    var otherItem = false
    var rejectAt: String?
    var failReadAfterSubmit = false
    var appInfoCount = 0
    var initialInfoState = "DEVELOPER_REJECTED"
    var timeoutAt: String?
    var unknownOtherRelationship = false
    var writes: [(method: String, path: String, body: Data?)] = []
    func configure(reversed: Bool = false, changedText: Bool = false, foreignPage: Bool = false, existing: Bool = false, editAfterItem: Bool = false) {
        reversedScreenshots = reversed; self.changedText = changedText
        self.foreignPage = foreignPage; existingSubmission = existing
        self.editAfterItem = editAfterItem
    }
    func configureSubmission(history: Bool = false, otherItem: Bool = false, rejectAt: String? = nil,
                             failReadAfterSubmit: Bool = false, timeoutAt: String? = nil, unknownOtherRelationship: Bool = false) {
        completedHistory = history; self.otherItem = otherItem; self.rejectAt = rejectAt
        self.failReadAfterSubmit = failReadAfterSubmit
        self.timeoutAt = timeoutAt; self.unknownOtherRelationship = unknownOtherRelationship
    }
    func configureInfo(count: Int = 1, state: String = "DEVELOPER_REJECTED") { appInfoCount = count; initialInfoState = state }
    func response(_ method: String, _ path: String, _ headers: [String: String], _ body: Data?) throws -> ASCDaemonClient.HTTPResponse {
        #expect(headers["Accept"] == "application/json")
        let url = try #require(URLComponents(string: path))
        var object: [String: Any]
        var code = 200
        if method != "GET" {
            writes.append((method, path, body))
            if path == timeoutAt { throw URLError(.timedOut) }
            if path == rejectAt {
                return ASCDaemonClient.HTTPResponse(statusCode: 409, headers: [:], contentType: "application/json",
                    body: try JSONSerialization.data(withJSONObject: ["errors": [["code": "ENTITY_ERROR.ATTRIBUTE.INVALID",
                        "source": ["pointer": "/data/attributes/submitted"], "detail": "secret-demo-password", "title": "private-user-value"]]]))
            }
            if path == "/v1/reviewSubmissionItems", editAfterItem { changedText = true }
            if path == "/v1/reviewSubmissions" {
                createdDraft = true
                object = ["data": ["id": "submission1", "type": "reviewSubmissions"]]
            } else if path == "/v1/reviewSubmissionItems" {
                addedVersion = true
                object = ["data": ["id": "item1", "type": "reviewSubmissionItems"]]
            } else if path.hasPrefix("/v1/reviewSubmissions/") {
                submitted = true
                object = ["data": ["id": String(path.split(separator: "/").last!), "type": "reviewSubmissions"]]
            }
            else { object = [:] }
        } else {
            if submitted && failReadAfterSubmit { throw ReleaseWorkflowAPIError.httpStatus(503) }
            switch url.path {
            case "/v1/apps/app1": object = ["data": ["id": "app1", "attributes": ["bundleId": "org.example.App", "name": "App"]]]
            case "/v1/apps/app1/appStoreVersions": object = ["data": [["id": "version1", "attributes": ["versionString": "1.2", "platform": "IOS", "appStoreState": submitted ? "WAITING_FOR_REVIEW" : (addedVersion || existingSubmission ? "READY_FOR_REVIEW" : "PREPARE_FOR_SUBMISSION"), "releaseType": "MANUAL"]]]]
            case "/v1/appStoreVersions/version1/build": object = ["data": ["id": "build1"]]
            case "/v1/appStoreVersions/version1/appStoreVersionLocalizations":
                object = ["data": [["id": "loc1", "attributes": ["locale": "de-DE", "description": changedText ? "New" : "Original"]]]]
                if foreignPage { object["links"] = ["next": "https://foreign.invalid/v1/appStoreVersions/version1/appStoreVersionLocalizations?limit=200"] }
            case "/v1/appStoreVersionLocalizations/loc1/appScreenshotSets":
                object = ["data": [["id": "set1", "attributes": ["screenshotDisplayType": "APP_IPHONE_67"]]]]
            case "/v1/appScreenshotSets/set1/appScreenshots":
                let shots = [["id": "shot1", "attributes": ["sourceFileChecksum": "a"]], ["id": "shot2", "attributes": ["sourceFileChecksum": "b"]]] as [[String: Any]]
                object = ["data": reversedScreenshots ? Array(shots.reversed()) : shots]
            case "/v1/appStoreVersionLocalizations/loc1/appPreviewSets": object = ["data": []]
            case "/v1/apps/app1/appInfos": object = ["data": (0..<appInfoCount).map { ["id": "info\($0)", "type": "appInfos",
                "attributes": ["state": addedVersion || existingSubmission ? "READY_FOR_REVIEW" : initialInfoState]] as [String: Any] }]
            case "/v1/appStoreVersions/version1/appStoreReviewDetail": object = [:]; code = 404
            case "/v1/reviewSubmissions":
                #expect(url.queryItems?.contains(URLQueryItem(name: "filter[app]", value: "app1")) == true)
                var list: [[String: Any]] = []
                if existingSubmission || createdDraft {
                    list.append(["id": existingSubmission ? "existing-submission" : "submission1",
                        "attributes": ["platform": "IOS", "state": submitted ? "WAITING_FOR_REVIEW" : "READY_FOR_REVIEW"],
                        "relationships": ["app": ["data": ["id": "app1", "type": "apps"]]]])
                }
                if completedHistory {
                    list.append(["id": "old-withdrawn", "attributes": ["platform": "IOS", "state": "COMPLETE", "submittedDate": "2026-11-11T20:16:05Z"],
                        "relationships": ["app": ["data": ["id": "app1", "type": "apps"]]]])
                }
                object = ["data": list]
            case "/v1/reviewSubmissions/existing-submission/items", "/v1/reviewSubmissions/submission1/items", "/v1/reviewSubmissions/old-withdrawn/items":
                var items: [[String: Any]] = existingSubmission || addedVersion || url.path.contains("old-withdrawn") ? [["id": "item1", "attributes": ["state": submitted ? "WAITING_FOR_REVIEW" : "READY_FOR_REVIEW"], "relationships": ["appStoreVersion": ["data": ["id": "version1", "type": "appStoreVersions"]]]]] : []
                if unknownOtherRelationship && !items.isEmpty {
                    var relationships = items[0]["relationships"] as? [String: Any] ?? [:]
                    relationships["appEvent"] = ["links": ["related": "/v1/appEvents/unknown"]]
                    items[0]["relationships"] = relationships
                }
                if otherItem { items.append(["id": "unrelated-item", "relationships": ["appEvent": ["data": ["id": "event1", "type": "appEvents"]]]]) }
                object = ["data": items]
            default:
                if url.path.hasPrefix("/v1/appInfos/info"), url.path.hasSuffix("/appInfoLocalizations") { object = ["data": []] }
                else if url.path.hasPrefix("/v1/appInfos/info"), url.path.hasSuffix("/ageRatingDeclaration") { object = ["data": NSNull()] }
                else { throw ReleaseWorkflowAPIError.invalidResponse }
            }
        }
        return ASCDaemonClient.HTTPResponse(statusCode: code, headers: [:], contentType: "application/json",
            body: try JSONSerialization.data(withJSONObject: object))
    }
}

private func fixtureAdapter(_ fixture: WorkflowSnapshotFixture) -> ReleaseWorkflowASCAdapter {
    ReleaseWorkflowASCAdapter(accountKey: "issuer:key", transport: { try await fixture.response($0, $1, $2, $3) },
        cli: { _ in throw ReleaseWorkflowAPIError.validationUnavailable }, loadBuild: { id in
            #expect(id == "build1")
            var build = ASCBuild(id: "build1", attributes: .init(version: "12", uploadedDate: nil,
                processingState: "VALID", expirationDate: nil, expired: false, minOsVersion: nil, iconAssetToken: nil))
            build.relationships = .init(app: .init(data: .init(id: "app1")), preReleaseVersion: .init(data: .init(id: "pre1")))
            build.preReleaseVersion = .init(id: "pre1", attributes: .init(version: "1.2", platform: "IOS"))
            return build
        }, readinessReport: { target in
            let report: [String: Any] = ["appId": target.appID, "versionId": target.versionID, "platform": target.platform,
                "checks": [], "summary": ["blocking": 0, "warnings": 0],
                "deep": ["checks": [], "summary": ["blocked": 0, "unverified": 0]]]
            let passed = ReleaseWebEvidence.Check(status: "passed", reason: "fixture_verified")
            return ReleaseReadinessPayload(report: try JSONSerialization.data(withJSONObject: report),
                web: .init(appId: target.appID, bundleId: target.bundleID, bindingVerified: true, bindingReason: "fixture_verified",
                           appleId: "fixture@example.invalid", providerId: "provider", developerTeamId: "team",
                           programLicense: passed, businessFree: passed, businessPaid: passed), exitCode: 0)
        })
}

@Test func releaseWorkflowAdapterProtectsTextsAndOrderedScreenshotsWithoutMutations() async throws {
    let fixture = WorkflowSnapshotFixture(), target = workflowTarget(workflowDirectory())
    let adapter = fixtureAdapter(fixture)
    let before = try await adapter.snapshot(target)
    #expect(before.attachedBuildID == "build1")
    #expect(before.versionString == "1.2")
    #expect(before.buildNumber == "12")
    await fixture.configure(reversed: true)
    let reordered = try await adapter.snapshot(target)
    #expect(reordered.contentDigest != before.contentDigest)
    await fixture.configure(changedText: true)
    let edited = try await adapter.snapshot(target)
    #expect(edited.contentDigest != before.contentDigest)
    #expect(await fixture.writes.isEmpty)
}

@Test func releaseWorkflowAdapterRejectsForeignPaginationAndExistingSubmission() async throws {
    let fixture = WorkflowSnapshotFixture(), target = workflowTarget(workflowDirectory())
    let adapter = fixtureAdapter(fixture)
    await fixture.configure(foreignPage: true)
    await #expect(throws: ReleaseWorkflowAPIError.self) { try await adapter.snapshot(target) }
    await fixture.configure(existing: true)
    let snapshot = try await adapter.snapshot(target)
    #expect(snapshot.submissionID == "existing-submission")
    #expect(snapshot.hasSubmissionConflict)
    await #expect(throws: ReleaseWorkflowError.self) { try await adapter.submit(target, expectedContentDigest: snapshot.contentDigest) }
    #expect(await fixture.writes.isEmpty)
}

@Test func releaseWorkflowAdapterSubmitUsesExactVersionAppAndPlatform() async throws {
    let fixture = WorkflowSnapshotFixture(), target = workflowTarget(workflowDirectory())
    let adapter = fixtureAdapter(fixture)
    let snapshot = try await adapter.snapshot(target)
    #expect(try await adapter.submit(target, expectedContentDigest: snapshot.contentDigest) == "submission1")
    let writes = await fixture.writes
    #expect(writes.map(\.method) == ["POST", "POST", "PATCH"])
    let createBody = try #require(writes.first?.body)
    let create = try #require(JSONSerialization.jsonObject(with: createBody) as? [String: Any])
    let data = try #require(create["data"] as? [String: Any])
    #expect((data["attributes"] as? [String: String])?["platform"] == "IOS")
    let app = ((data["relationships"] as? [String: [String: Any]])?["app"]?["data"] as? [String: String])
    #expect(app?["id"] == "app1")
    let itemBody = try #require(writes[1].body)
    let item = try #require(JSONSerialization.jsonObject(with: itemBody) as? [String: Any])
    let itemData = try #require(item["data"] as? [String: Any])
    let version = ((itemData["relationships"] as? [String: [String: Any]])?["appStoreVersion"]?["data"] as? [String: String])
    #expect(version?["id"] == "version1")
}

@Test func releaseWorkflowAdapterDoesNotConfirmIfContentChangesAfterSubmissionItem() async throws {
    let fixture = WorkflowSnapshotFixture(), target = workflowTarget(workflowDirectory())
    let adapter = fixtureAdapter(fixture)
    let snapshot = try await adapter.snapshot(target)
    await fixture.configure(editAfterItem: true)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await adapter.submit(target, expectedContentDigest: snapshot.contentDigest)
    }
    #expect(await fixture.writes.map(\.method) == ["POST", "POST"])
}

@Test func releaseWorkflowCanReprepareChangedContentAfterKnownReleaseModeEffect() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let record = try await service.prepare(target: workflowTarget(root), mode: .automaticAfterApproval)
    _ = try await service.validate(operationID: record.operationID, accountKey: "issuer:key")
    await api.configure(modeFails: true)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: "issuer:key", confirmationDigest: record.confirmationDigest)
    }
    await api.configure(value: workflowSnapshot(content: "edited", mode: "AFTER_APPROVAL"))
    let status = try await service.status(operationID: record.operationID, accountKey: "issuer:key")
    #expect(status.state == .needsPreparation)
    let new = try await service.prepare(target: workflowTarget(root), mode: .automaticAfterApproval)
    #expect(new.operationID != record.operationID)
    #expect(await api.modeWrites == 1)
    #expect(await api.submissions == 0)
}

@Test func releaseWorkflowRejectsTamperedRecordEvenWithOldConfirmationValue() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    let path = root.appendingPathComponent("\(record.operationID).json")
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    var target = try #require(json["target"] as? [String: Any])
    target["appId"] = "otherApp"; json["target"] = target
    try JSONSerialization.data(withJSONObject: json).write(to: path)
    await #expect(throws: ReleaseWorkflowError.self) { try await service.loadRecord(operationID: record.operationID) }
    #expect(await api.submissions == 0)
}

@Test func releaseWorkflowExplicitUIAttachmentIsJournaledAndReadOnlyRecovered() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let target = workflowTarget(root)
    await api.configure(value: workflowSnapshot(attached: nil))
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.prepareAfterAttachingBuild(target: target, mode: .manual) {
            // Simulate an applied PATCH followed by a lost response.
            await api.configure(value: workflowSnapshot())
            throw ReleaseWorkflowAPIError.httpStatus(503)
        }
    }
    let pending = try #require(await service.activeOperation(target: target))
    #expect(pending.state == .attachmentPending)
    await #expect(throws: ReleaseWorkflowError.self) { try await service.prepare(target: target, mode: .manual) }
    let status = try await service.status(operationID: pending.operationID, accountKey: "issuer:key")
    #expect(status.state == .prepared)
    #expect(await api.submissions == 0)
}

@Test func releaseWorkflowDoesNotReconcileAnotherAttachedBuildAsSubmitted() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let api = WorkflowMockAPI(), service = ReleaseWorkflowService(directory: root, api: api)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    _ = try await service.validate(operationID: record.operationID, accountKey: "issuer:key")
    await api.configure(submitFails: true)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: "issuer:key", confirmationDigest: record.confirmationDigest)
    }
    await api.configure(value: workflowSnapshot(attached: "another-build", state: "WAITING_FOR_REVIEW"))
    await #expect(throws: ReleaseWorkflowError.self) { try await service.status(operationID: record.operationID, accountKey: "issuer:key") }
    let saved = try await service.loadRecord(operationID: record.operationID)
    #expect(saved.state == .submissionPending)
    #expect(await api.submissions == 1)
}

@Test func releaseWorkflowAdapterRejectsMixedDataAndErrorsEvenForHTTP200() async throws {
    let fixture = WorkflowSnapshotFixture()
    let base = fixtureAdapter(fixture)
    let adapter = ReleaseWorkflowASCAdapter(accountKey: "issuer:key", transport: { method, path, headers, body in
        let response = try await fixture.response(method, path, headers, body)
        if URLComponents(string: path)?.path == "/v1/reviewSubmissions" {
            var object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            object["errors"] = [["code": "PARTIAL_RESULT", "detail": "Collection is incomplete"]]
            return ASCDaemonClient.HTTPResponse(statusCode: 200, headers: [:], contentType: "application/json",
                body: try JSONSerialization.data(withJSONObject: object))
        }
        return response
    }, cli: { _ in throw ReleaseWorkflowAPIError.validationUnavailable }, loadBuild: { _ in
        throw ReleaseWorkflowAPIError.invalidResponse
    })
    let target = workflowTarget(workflowDirectory())
    let snapshot = try await base.snapshot(target)
    await #expect(throws: ReleaseWorkflowAPIError.self) {
        try await adapter.submit(target, expectedContentDigest: snapshot.contentDigest)
    }
    #expect(await fixture.writes.isEmpty)
}

@Test func releaseWorkflowNewSubmissionAcceptsReadyForReviewAndKeepsEachBoundary() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = WorkflowSnapshotFixture(), adapter = fixtureAdapter(fixture)
    let service = ReleaseWorkflowService(directory: root, api: adapter)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    _ = try await service.validate(operationID: record.operationID, accountKey: record.target.accountKey)
    let result = try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
                                          confirmationDigest: record.confirmationDigest)
    #expect(result.state == .submitted)
    #expect(result.submissionProgress?.phase == .acknowledged)
    #expect(result.submissionID == "submission1")
    #expect(await fixture.writes.map(\.method) == ["POST", "POST", "PATCH"])
}

@Test func releaseWorkflowCurrentDraftWinsOverDatedWithdrawnHistory() async throws {
    let fixture = WorkflowSnapshotFixture(), target = workflowTarget(workflowDirectory())
    await fixture.configure(existing: true)
    await fixture.configureSubmission(history: true)
    let snapshot = try await fixtureAdapter(fixture).snapshot(target)
    #expect(snapshot.submissionID == "existing-submission")
    #expect(snapshot.submissionState == "READY_FOR_REVIEW")
    #expect(snapshot.canResumeSubmission)
    #expect(await fixture.writes.isEmpty)
}

/// Emulate a pre-phase-journaling operation interrupted after item creation.
private func legacyPending(_ record: ReleaseWorkflowRecord, root: URL, legacyDigest: String? = nil) throws {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    object["state"] = "submissionPending"
    object["submissionId"] = "old-withdrawn"
    object["lastErrorCode"] = "submission_outcome_unknown"
    object.removeValue(forKey: "submissionProgress")
    if let legacyDigest {
        struct LegacyConfirmation: Encodable {
            let target: ReleaseWorkflowTarget
            let mode: ReleaseWorkflowMode
            let operationID: String
            let versionString: String
            let buildNumber: String
            let contentDigest: String
        }
        object["contentDigest"] = legacyDigest
        object.removeValue(forKey: "contentFingerprintVersion")
        object["confirmationDigest"] = try ReleaseWorkflowService.digest(LegacyConfirmation(target: record.target, mode: record.mode,
            operationID: record.operationID, versionString: record.versionString, buildNumber: record.buildNumber, contentDigest: legacyDigest))
    }
    try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("\(record.operationID).json"))
}

@Test func releaseWorkflowFingerprintMigrationProvesOnlyAppInfoStateChanged() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = WorkflowSnapshotFixture(), adapter = fixtureAdapter(fixture), target = workflowTarget(root)
    await fixture.configureInfo()
    let before = try await adapter.snapshot(target)
    let oldDigest = try #require(before.legacyContentDigests.first)
    let service = ReleaseWorkflowService(directory: root, api: adapter)
    let record = try await service.prepare(target: target, mode: .manual)
    try legacyPending(record, root: root, legacyDigest: oldDigest)
    await fixture.configure(existing: true)
    let after = try await adapter.snapshot(target)
    #expect(before.contentDigest == after.contentDigest)
    #expect(after.matchesContentDigest(oldDigest, fingerprintVersion: nil))
    let status = try await service.status(operationID: record.operationID, accountKey: target.accountKey)
    #expect(status.resumableSubmissionID == "existing-submission")
    #expect(status.requiresLegacyRecoveryConfirmation == true)
    #expect(status.contentDigest == oldDigest)
    #expect(status.contentFingerprintVersion == nil)
    await fixture.configure(changedText: true, existing: true)
    let changed = try await adapter.snapshot(target)
    #expect(!changed.matchesContentDigest(oldDigest, fingerprintVersion: nil))
    let invalid = try await service.status(operationID: record.operationID, accountKey: target.accountKey)
    #expect(invalid.resumableSubmissionID == nil)
    #expect(await fixture.writes.isEmpty)
}

@Test func releaseWorkflowFingerprintCompatibilityHasFiniteBound() async throws {
    let fixture = WorkflowSnapshotFixture(), adapter = fixtureAdapter(fixture), target = workflowTarget(workflowDirectory())
    await fixture.configureInfo(count: 4)
    let before = try await adapter.snapshot(target)
    let oldDigest = try #require(before.legacyContentDigests.first)
    await fixture.configure(existing: true)
    let after = try await adapter.snapshot(target)
    #expect(before.contentDigest == after.contentDigest)
    #expect(after.legacyContentDigests.count == 1)
    #expect(!after.matchesContentDigest(oldDigest, fingerprintVersion: nil))
}

@Test func releaseWorkflowRecordedDraftCannotBeReplacedByAnotherMatchingDraft() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = WorkflowSnapshotFixture(), adapter = fixtureAdapter(fixture)
    let service = ReleaseWorkflowService(directory: root, api: adapter)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    _ = try await service.validate(operationID: record.operationID, accountKey: record.target.accountKey)
    await fixture.configure(editAfterItem: true)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
                                 confirmationDigest: record.confirmationDigest)
    }
    await fixture.configure(existing: true)
    let status = try await service.status(operationID: record.operationID, accountKey: record.target.accountKey)
    #expect(status.submissionID == "submission1")
    #expect(status.submissionItemID == "item1")
    #expect(status.resumableSubmissionID == nil)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
            confirmationDigest: record.confirmationDigest, resumeSubmissionID: "existing-submission")
    }
    #expect(await fixture.writes.count == 2)
}

@Test func releaseWorkflowLegacyDraftRequiresExactExplicitResumeAndPerformsOnlyPatch() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = WorkflowSnapshotFixture(), adapter = fixtureAdapter(fixture)
    let service = ReleaseWorkflowService(directory: root, api: adapter)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    try legacyPending(record, root: root)
    await fixture.configure(existing: true)
    await fixture.configureSubmission(history: true)
    let status = try await service.status(operationID: record.operationID, accountKey: record.target.accountKey)
    #expect(status.state == .submissionPending)
    #expect(status.submissionID == "existing-submission")
    #expect(status.resumableSubmissionID == "existing-submission")
    #expect(await fixture.writes.isEmpty)
    for id in [nil, "old-withdrawn", "other-draft", "existing-submission"] as [String?] {
        await #expect(throws: ReleaseWorkflowError.self) {
            try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
                                     confirmationDigest: record.confirmationDigest, resumeSubmissionID: id)
        }
    }
    _ = try await service.validate(operationID: record.operationID, accountKey: record.target.accountKey)
    let submitted = try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
        confirmationDigest: record.confirmationDigest, resumeSubmissionID: "existing-submission", confirmLegacyDraftRecovery: true)
    #expect(submitted.state == .submitted)
    #expect(await fixture.writes.map(\.method) == ["PATCH"])
    #expect(await fixture.writes.first?.path == "/v1/reviewSubmissions/existing-submission")
}

@Test func releaseWorkflowNeverResumesDraftContainingAdditionalContent() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = WorkflowSnapshotFixture(), adapter = fixtureAdapter(fixture)
    let service = ReleaseWorkflowService(directory: root, api: adapter)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    try legacyPending(record, root: root)
    await fixture.configure(existing: true)
    await fixture.configureSubmission(otherItem: true)
    let status = try await service.status(operationID: record.operationID, accountKey: record.target.accountKey)
    #expect(status.resumableSubmissionID == nil)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
            confirmationDigest: record.confirmationDigest, resumeSubmissionID: "existing-submission")
    }
    #expect(await fixture.writes.isEmpty)
}

@Test func releaseWorkflowPersistsCreatedIDAndSanitizedAppleFailureBeforeRestart() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = WorkflowSnapshotFixture(), adapter = fixtureAdapter(fixture)
    let service = ReleaseWorkflowService(directory: root, api: adapter)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    _ = try await service.validate(operationID: record.operationID, accountKey: record.target.accountKey)
    await fixture.configureSubmission(rejectAt: "/v1/reviewSubmissionItems")
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
                                 confirmationDigest: record.confirmationDigest)
    }
    let restarted = ReleaseWorkflowService(directory: root, api: adapter)
    let saved = try await restarted.loadRecord(operationID: record.operationID)
    #expect(saved.state == .submissionPending)
    #expect(saved.submissionID == "submission1")
    #expect(saved.submissionProgress?.phase == .addingVersion)
    #expect(saved.lastDiagnostic?.apple?.httpStatus == 409)
    #expect(saved.lastDiagnostic?.apple?.codes == ["ENTITY_ERROR.ATTRIBUTE.INVALID"])
    #expect(saved.lastDiagnostic?.apple?.pointers == ["/data/attributes/submitted"])
    let contents = try String(contentsOf: root.appendingPathComponent("\(record.operationID).json"), encoding: .utf8)
    #expect(!contents.contains("secret-demo-password") && !contents.contains("private-user-value"))
    #expect(await fixture.writes.map(\.method) == ["POST", "POST"])
}

@Test func releaseWorkflowFinalPatchIntentCannotBeResumedEvenWithSameDraftID() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = WorkflowSnapshotFixture(), adapter = fixtureAdapter(fixture)
    let service = ReleaseWorkflowService(directory: root, api: adapter)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    _ = try await service.validate(operationID: record.operationID, accountKey: record.target.accountKey)
    await fixture.configureSubmission(rejectAt: "/v1/reviewSubmissions/submission1")
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
                                 confirmationDigest: record.confirmationDigest)
    }
    let status = try await service.status(operationID: record.operationID, accountKey: record.target.accountKey)
    #expect(status.submissionProgress?.phase == .submitting)
    #expect(status.resumableSubmissionID == nil)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
            confirmationDigest: record.confirmationDigest, resumeSubmissionID: "submission1")
    }
    #expect(await fixture.writes.count == 3)
}

@Test func releaseWorkflowKeepsAcceptedPatchWhenStatusReadFailsAndReconcilesWithoutWrites() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = WorkflowSnapshotFixture(), adapter = fixtureAdapter(fixture)
    let service = ReleaseWorkflowService(directory: root, api: adapter)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    _ = try await service.validate(operationID: record.operationID, accountKey: record.target.accountKey)
    await fixture.configureSubmission(failReadAfterSubmit: true)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
                                 confirmationDigest: record.confirmationDigest)
    }
    let saved = try await service.loadRecord(operationID: record.operationID)
    #expect(saved.submissionProgress?.phase == .acknowledged)
    #expect(saved.submissionID == "submission1")
    #expect(saved.lastErrorCode == "submission_accepted_status_unverified")
    await fixture.configureSubmission()
    let status = try await service.status(operationID: record.operationID, accountKey: record.target.accountKey)
    #expect(status.state == .submitted)
    #expect(status.lastDiagnostic == nil)
    #expect(await fixture.writes.count == 3)
}

@Test func releaseWorkflowCheckingExistingCannotAdoptForeignDraft() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = WorkflowSnapshotFixture(), adapter = fixtureAdapter(fixture)
    let service = ReleaseWorkflowService(directory: root, api: adapter)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    try legacyPending(record, root: root)
    let file = root.appendingPathComponent("\(record.operationID).json")
    var journal = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    journal["submissionProgress"] = ["phase": "checkingExisting"]
    journal.removeValue(forKey: "submissionId")
    try JSONSerialization.data(withJSONObject: journal).write(to: file)
    await fixture.configure(existing: true)
    let status = try await service.status(operationID: record.operationID, accountKey: record.target.accountKey)
    #expect(status.resumableSubmissionID == nil)
    #expect(status.requiresLegacyRecoveryConfirmation == nil)
    #expect(status.submissionID == nil)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
            confirmationDigest: record.confirmationDigest, resumeSubmissionID: "existing-submission", confirmLegacyDraftRecovery: true)
    }
    #expect(await fixture.writes.isEmpty)
}

@Test func releaseWorkflowDraftWithUnresolvedOtherContentRelationshipIsNotResumable() async throws {
    let fixture = WorkflowSnapshotFixture(), adapter = fixtureAdapter(fixture), target = workflowTarget(workflowDirectory())
    await fixture.configure(existing: true)
    await fixture.configureSubmission(unknownOtherRelationship: true)
    let snapshot = try await adapter.snapshot(target)
    #expect(!snapshot.canResumeSubmission)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await adapter.submit(target, expectedContentDigest: snapshot.contentDigest, resumingSubmissionID: "existing-submission")
    }
    #expect(await fixture.writes.isEmpty)
}

@Test func releaseWorkflowLostFinalPatchReplyNeverAllowsExplicitReplay() async throws {
    let root = workflowDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = WorkflowSnapshotFixture(), adapter = fixtureAdapter(fixture)
    let service = ReleaseWorkflowService(directory: root, api: adapter)
    let record = try await service.prepare(target: workflowTarget(root), mode: .manual)
    _ = try await service.validate(operationID: record.operationID, accountKey: record.target.accountKey)
    await fixture.configureSubmission(timeoutAt: "/v1/reviewSubmissions/submission1")
    await #expect(throws: ReleaseWorkflowError.self) {
        try await service.submit(operationID: record.operationID, accountKey: record.target.accountKey,
                                 confirmationDigest: record.confirmationDigest)
    }
    let restarted = ReleaseWorkflowService(directory: root, api: adapter)
    let status = try await restarted.status(operationID: record.operationID, accountKey: record.target.accountKey)
    #expect(status.submissionProgress?.phase == .submitting)
    #expect(status.lastDiagnostic?.category == "request_outcome_unknown")
    #expect(status.resumableSubmissionID == nil)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await restarted.submit(operationID: record.operationID, accountKey: record.target.accountKey,
            confirmationDigest: record.confirmationDigest, resumeSubmissionID: "submission1", confirmLegacyDraftRecovery: true)
    }
    #expect(await fixture.writes.count == 3)
}
