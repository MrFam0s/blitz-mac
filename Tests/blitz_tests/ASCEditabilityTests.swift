import Foundation
import Testing
@testable import Blitz

private func editVersion(_ state: String?, id: String = "version") -> ASCAppStoreVersion {
    ASCAppStoreVersion(id: id, attributes: .init(versionString: "1.0", appStoreState: state,
        releaseType: nil, createdDate: nil, copyright: nil))
}
private func editInfo(_ state: String?, id: String = "info") -> ASCAppInfo {
    ASCAppInfo(id: id, attributes: .init(appStoreState: state), relationships: nil)
}
@MainActor private func editManager(state: String = "PREPARE_FOR_SUBMISSION") -> ASCManager {
    let manager = ASCManager()
    manager.app = ASCApp(id: "app", attributes: .init(bundleId: "org.example.test", name: "Test",
        primaryLocale: "en-US", vendorNumber: nil, contentRightsDeclaration: nil), relationships: nil)
    manager.appStoreVersions = [editVersion(state)]
    manager.selectedVersionId = "version"
    manager.appInfo = editInfo(state)
    return manager
}

@Test(arguments: ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "REMOVED_FROM_SALE", "REPLACED_WITH_NEW_VERSION", "FUTURE_UNKNOWN_STATE", ""])
func lockedAndUnknownStatesNeverEnableVersionEdits(_ state: String) {
    #expect(!ASCReleaseStatus.isEditable(state))
    let version = editVersion(state), info = editInfo(state)
    for field in ASCEditability.versionFields.union(ASCEditability.appInfoFields) {
        #expect(!ASCEditability.allows(field, version: version, appInfo: info))
    }
    for field in ["promotionalText", "copyright", "reviewContact"] {
        #expect(ASCEditability.allows(field, version: version, appInfo: info))
    }
}

@Test(arguments: ["PREPARE_FOR_SUBMISSION", "REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED", "INVALID_BINARY"])
func knownEditableStatesPermitScreenshotAndMetadataChanges(_ state: String) {
    for field in ASCEditability.versionFields.union(ASCEditability.appInfoFields) {
        #expect(ASCEditability.allows(field, version: editVersion(state), appInfo: editInfo(state)))
    }
}

@Test func appInfoUsesItsOwnResourceStatusAndDoesNotAssumeFirstRecordIsEditable() {
    #expect(!ASCEditability.allows("name", version: editVersion("PREPARE_FOR_SUBMISSION"), appInfo: editInfo("READY_FOR_SALE")))
    #expect(ASCEditability.allows("name", version: editVersion("READY_FOR_SALE"), appInfo: editInfo("PREPARE_FOR_SUBMISSION")))
    #expect(!ASCEditability.allows("privacyPolicyUrl", version: editVersion("PREPARE_FOR_SUBMISSION"), appInfo: editInfo(nil)))
    #expect(ASCEditability.preferredAppInfo([editInfo("READY_FOR_SALE", id: "live"), editInfo("PREPARE_FOR_SUBMISSION", id: "draft")])?.id == "draft")
    #expect(!ASCEditability.allows("unrecognized", version: editVersion("PREPARE_FOR_SUBMISSION"), appInfo: nil))
}

@MainActor private final class WriteStateStub: ASCWriteStateService {
    var state = "PREPARE_FOR_SUBMISSION"
    var onRead: (() -> Void)?
    var reads = 0
    var shouldFail = false
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] {
        reads += 1
        onRead?()
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return [editVersion(state)]
    }
    func fetchAppInfoRecord(id: String) async throws -> ASCAppInfo {
        reads += 1
        onRead?()
        return editInfo(state, id: id)
    }
}

@MainActor @Test func knownLockedWriteIsRejectedWithoutNetworkRequest() async {
    let manager = editManager(state: "READY_FOR_SALE"), service = WriteStateStub()
    do { _ = try await manager.validateWrite(fields: ["screenshots"], using: service); Issue.record("Live screenshots must not be mutated") }
    catch { #expect(service.reads == 0) }
}

@MainActor @Test func cachedEditableVersionIsRecheckedBeforeWriting() async {
    let manager = editManager(), service = WriteStateStub()
    service.state = "IN_REVIEW"
    do { _ = try await manager.validateWrite(fields: ["screenshots"], using: service); Issue.record("Stale editable status must not permit writes") }
    catch {
        #expect(service.reads == 1)
        #expect(!manager.canEditField("screenshots"))
    }
}

@MainActor @Test func metadataBatchIsRejectedBeforeAnyWriteIfOneFieldIsLocked() async {
    let manager = editManager(state: "READY_FOR_SALE"), service = WriteStateStub()
    do { _ = try await manager.validateWrite(fields: ["promotionalText", "description"], using: service); Issue.record("Mixed locked batch must fail") }
    catch { #expect(service.reads == 0) }
}

@MainActor @Test func failedFreshReadAndChangedTargetCannotAuthorizeWrite() async {
    let manager = editManager(), service = WriteStateStub()
    service.shouldFail = true
    do { _ = try await manager.validateWrite(fields: ["screenshots"], using: service); Issue.record("Offline status must not authorize writes") } catch {}
    service.shouldFail = false
    service.onRead = { manager.projectRevision = UUID() }
    do { _ = try await manager.validateWrite(fields: ["screenshots"], using: service); Issue.record("Changed project must cancel writes") }
    catch { #expect(error is CancellationError) }
}

@MainActor @Test func appInfoStatusIsRecheckedIndependently() async {
    let manager = editManager(), service = WriteStateStub()
    service.state = "READY_FOR_SALE"
    do { _ = try await manager.validateWrite(fields: ["name"], using: service); Issue.record("Live AppInfo must not be edited") }
    catch { #expect(!manager.canEditField("name")); #expect(service.reads == 1) }
}

@MainActor @Test func lockedScreenshotTrackDoesNotAcceptLocalChangesOrSave() async {
    let manager = editManager(state: "READY_FOR_SALE")
    let key = manager.screenshotTrackKey(displayType: "APP_IPHONE_67", locale: "en-US")
    manager.trackSlots[key] = [TrackSlot(id: "remote", localPath: nil, localImage: nil, ascScreenshot: nil, isFromASC: true)] + Array(repeating: nil, count: 9)
    manager.removeFromTrack(displayType: "APP_IPHONE_67", slotIndex: 0)
    manager.reorderTrack(displayType: "APP_IPHONE_67", fromIndex: 0, toIndex: 1)
    #expect(manager.trackSlots[key]?[0]?.id == "remote")
    #expect(manager.addAssetToTrack(displayType: "APP_IPHONE_67", slotIndex: 1, localPath: "/missing") == manager.screenshotEditingMessage)
    await manager.syncTrackToASC(displayType: "APP_IPHONE_67", locale: "en-US")
    #expect(manager.writeError == manager.screenshotEditingMessage)
}

@Test func appInfoStatusDecodesFromServerAndOldCacheRemainsReadOnly() throws {
    let data = Data(#"{"id":"info","attributes":{"appStoreState":"READY_FOR_SALE"}}"#.utf8)
    #expect(try JSONDecoder().decode(ASCAppInfo.self, from: data).attributes?.appStoreState == "READY_FOR_SALE")
    let cached = try JSONDecoder().decode(ASCAppInfo.self, from: Data(#"{"id":"info","attributes":{}}"#.utf8))
    #expect(!ASCEditability.allows("name", version: editVersion("PREPARE_FOR_SUBMISSION"), appInfo: cached))
}

@Test func productReviewAndLocalizationUseProductStatusRatherThanAppVersion() throws {
    for state in ["MISSING_METADATA", "READY_TO_SUBMIT", "REJECTED", "DEVELOPER_REJECTED"] {
        try ASCEditability.validateProductChanges(state: state, oldReviewNote: "old", reviewNote: "new", changesLocalization: true)
    }
    for state in ["APPROVED", "IN_REVIEW", "WAITING_FOR_REVIEW", "READY_FOR_REVIEW", "ACCEPTED", "UNKNOWN", ""] {
        #expect(!ASCEditability.canEditProductReview(state))
        #expect(throws: (any Error).self) {
            try ASCEditability.validateProductChanges(state: state, oldReviewNote: "old", reviewNote: "new", changesLocalization: false)
        }
        // An unchanged review note must not block an independent reference-name change.
        try ASCEditability.validateProductChanges(state: state, oldReviewNote: "old", reviewNote: "old", changesLocalization: false)
    }
    #expect(ASCEditability.canEditProductLocalization("APPROVED"))
    #expect(throws: (any Error).self) {
        try ASCEditability.validateProductChanges(state: "IN_REVIEW", oldReviewNote: nil, reviewNote: nil, changesLocalization: true)
    }
}
