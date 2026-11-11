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
        attachedBuildID: attached, appleState: state, releaseType: mode, contentDigest: content)
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
    func submit(_ target: ReleaseWorkflowTarget, expectedContentDigest: String) async throws -> String? {
        submissions += 1
        if submitFails { throw ReleaseWorkflowAPIError.httpStatus(503) }
        value = workflowSnapshot(state: "WAITING_FOR_REVIEW", mode: value.releaseType ?? "MANUAL")
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
    var writes: [(method: String, path: String, body: Data?)] = []
    func configure(reversed: Bool = false, changedText: Bool = false, foreignPage: Bool = false, existing: Bool = false, editAfterItem: Bool = false) {
        reversedScreenshots = reversed; self.changedText = changedText
        self.foreignPage = foreignPage; existingSubmission = existing
        self.editAfterItem = editAfterItem
    }
    func response(_ method: String, _ path: String, _ headers: [String: String], _ body: Data?) throws -> ASCDaemonClient.HTTPResponse {
        #expect(headers["Accept"] == "application/json")
        let url = try #require(URLComponents(string: path))
        var object: [String: Any]
        var code = 200
        if method != "GET" {
            writes.append((method, path, body))
            if path == "/v1/reviewSubmissionItems", editAfterItem { changedText = true }
            if path == "/v1/reviewSubmissions" { object = ["data": ["id": "submission1", "type": "reviewSubmissions"]] }
            else { object = [:] }
        } else {
            switch url.path {
            case "/v1/apps/app1": object = ["data": ["id": "app1", "attributes": ["bundleId": "org.example.App", "name": "App"]]]
            case "/v1/apps/app1/appStoreVersions": object = ["data": [["id": "version1", "attributes": ["versionString": "1.2", "platform": "IOS", "appStoreState": "PREPARE_FOR_SUBMISSION", "releaseType": "MANUAL"]]]]
            case "/v1/appStoreVersions/version1/build": object = ["data": ["id": "build1"]]
            case "/v1/appStoreVersions/version1/appStoreVersionLocalizations":
                object = ["data": [["id": "loc1", "attributes": ["locale": "de-DE", "description": changedText ? "New" : "Original"]]]]
                if foreignPage { object["links"] = ["next": "https://foreign.invalid/v1/appStoreVersions/version1/appStoreVersionLocalizations?limit=200"] }
            case "/v1/appStoreVersionLocalizations/loc1/appScreenshotSets":
                object = ["data": [["id": "set1", "attributes": ["screenshotDisplayType": "APP_IPHONE_67"]]]]
            case "/v1/appScreenshotSets/set1/appScreenshots":
                let shots = [["id": "shot1", "attributes": ["sourceFileChecksum": "a"]], ["id": "shot2", "attributes": ["sourceFileChecksum": "b"]]] as [[String: Any]]
                object = ["data": reversedScreenshots ? Array(shots.reversed()) : shots]
            case "/v1/appStoreVersionLocalizations/loc1/appPreviewSets", "/v1/apps/app1/appInfos": object = ["data": []]
            case "/v1/appStoreVersions/version1/appStoreReviewDetail": object = [:]; code = 404
            case "/v1/reviewSubmissions":
                #expect(url.queryItems?.contains(URLQueryItem(name: "filter[app]", value: "app1")) == true)
                object = ["data": existingSubmission ? [["id": "existing-submission", "attributes": ["platform": "IOS", "state": "READY_FOR_REVIEW"], "relationships": ["app": ["data": ["id": "app1", "type": "apps"]]]]] : []]
            case "/v1/reviewSubmissions/existing-submission/items":
                object = ["data": [["id": "item1", "relationships": ["appStoreVersion": ["data": ["id": "version1", "type": "appStoreVersions"]]]]]]
            default: throw ReleaseWorkflowAPIError.invalidResponse
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
