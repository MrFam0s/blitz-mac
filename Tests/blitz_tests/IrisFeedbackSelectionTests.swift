import Foundation
import Testing
@testable import Blitz

private func feedbackVersion(_ id: String, _ platform: String = "IOS", number: String = "1.2.1", state: String = "REJECTED") -> ASCAppStoreVersion {
    ASCAppStoreVersion(id: id, attributes: .init(versionString: number, appStoreState: state, releaseType: nil, createdDate: nil, copyright: nil, platform: platform))
}

@Test func irisFeedbackKeepsUnassignedConversationWithoutInventingVersion() throws {
    var cycle = IrisFeedbackCycle.empty(id: "app-wide")
    cycle.messages = [.init(id: "question", body: "Please explain the feature.", createdAt: nil, sender: .apple),
                      .init(id: "reply", body: "Here is our explanation.", createdAt: nil, sender: .developer)]
    let version = feedbackVersion("ios")
    let selection = IrisFeedbackSelection(cycles: [cycle], version: version, knownVersions: [version])
    #expect(selection.matched.isEmpty)
    #expect(selection.unassigned.count == 1)
    #expect(selection.hasMessages)
    let payload = try #require(IrisFeedbackSelection.payload(selection.unassigned).first)
    #expect(payload["version"] is NSNull)
    #expect(payload["submissionId"] is NSNull)
    let messages = try #require(payload["messages"] as? [[String: Any]])
    #expect(messages.compactMap { $0["sender"] as? String } == ["apple", "developer"])
    #expect(messages.compactMap { $0["body"] as? String } == cycle.messages.map(\.body))
}

@Test func irisFeedbackUsesVersionResourceInsteadOfSameNumberOnAnotherPlatform() {
    let ios = feedbackVersion("ios"), mac = feedbackVersion("mac", "MAC_OS")
    var cycle = IrisFeedbackCycle.empty(id: "linked")
    cycle.versionString = "1.2.1"
    cycle.appStoreVersionIDs = ["mac"]
    let selection = IrisFeedbackSelection(cycles: [cycle], version: ios, knownVersions: [ios, mac])
    #expect(!selection.hasMessages)
    let macSelection = IrisFeedbackSelection(cycles: [cycle], version: mac, knownVersions: [ios, mac])
    #expect(macSelection.matched.map(\.id) == ["linked"])
}

@Test func irisFeedbackAmbiguousLegacyMarkerRemainsUnassigned() {
    let ios = feedbackVersion("ios"), mac = feedbackVersion("mac", "MAC_OS")
    var cycle = IrisFeedbackCycle.empty(id: "legacy")
    cycle.versionString = "1.2.1"
    let selection = IrisFeedbackSelection(cycles: [cycle], version: ios, knownVersions: [ios, mac])
    #expect(selection.matched.isEmpty)
    #expect(selection.unassigned.map(\.id) == ["legacy"])
    let unique = IrisFeedbackSelection(cycles: [cycle], version: ios, knownVersions: [ios])
    #expect(unique.matched.map(\.id) == ["legacy"])
}

@MainActor @Test func irisUnassignedQuestionsCannotCreateVersionRejectionHistory() {
    let manager = ASCManager()
    let ios = feedbackVersion("ios"), mac = feedbackVersion("mac", "MAC_OS")
    manager.appStoreVersions = [ios, mac]
    var cycle = IrisFeedbackCycle.empty(id: "unassigned")
    cycle.messages = [.init(id: "m", body: "Please clarify.", createdAt: nil, sender: .apple)]
    cycle.reasons = [.init(id: "r", section: "Information needed", description: "Explain feature", code: "2.1")]
    manager.irisFeedbackCycles = [cycle]
    manager.rebuildSubmissionHistory(appId: "fixture")
    #expect(!manager.hasIrisFeedback(for: ios))
    #expect(manager.submissionHistoryEvents.isEmpty)
    cycle.appStoreVersionIDs = [mac.id]
    manager.irisFeedbackCycles = [cycle]
    manager.rebuildSubmissionHistory(appId: "fixture")
    #expect(!manager.hasIrisFeedback(for: ios))
    #expect(manager.hasIrisFeedback(for: mac))
    #expect(manager.submissionHistoryEvents.map(\.versionId) == [mac.id])
    cycle.appStoreVersionIDs = [ios.id, mac.id]
    manager.irisFeedbackCycles = [cycle]
    manager.rebuildSubmissionHistory(appId: "fixture")
    #expect(!manager.hasIrisFeedback(for: ios) && !manager.hasIrisFeedback(for: mac))
    #expect(manager.submissionHistoryEvents.isEmpty)
    cycle.appStoreVersionIDs = [mac.id]
    cycle.reasons = []
    manager.irisFeedbackCycles = [cycle]
    manager.rebuildSubmissionHistory(appId: "fixture")
    #expect(!manager.hasIrisFeedback(for: mac))
    #expect(manager.submissionHistoryEvents.isEmpty)
}

private struct MalformedIrisFeedback: IrisFeedbackService {
    func fetchResolutionCenterThreadPages(appId: String) async throws -> [IrisRawPage] {
        [IrisRawPage(url: "https://appstoreconnect.apple.com/iris/v1/apps/fixture/resolutionCenterThreads", data: Data(#"{"data":{"unexpected":"object"}}"#.utf8))]
    }
    func fetchMessagesAndRejectionsPages(threadId: String) async throws -> [IrisRawPage] { [] }
}

@MainActor @Test func irisMalformedFetchIsAnErrorAndDoesNotBecomeSuccessfulEmptyCache() async throws {
    let manager = ASCManager()
    manager.app = try JSONDecoder().decode(ASCApp.self, from: Data(#"{"id":"fixture-malformed","attributes":{"name":"Fixture","bundleId":"org.example.fixture"}}"#.utf8))
    manager.irisSessionState = .valid
    manager.irisFeedbackCycles = [.empty(id: "keep-existing")]
    await manager.fetchRejectionFeedback(force: true, using: MalformedIrisFeedback())
    #expect(manager.irisFeedbackError != nil)
    #expect(!manager.isLoadingIrisFeedback)
    #expect(manager.irisLastFetchedAtByAppId["fixture-malformed"] == nil)
    #expect(manager.irisFeedbackCycles.map(\.id) == ["keep-existing"])
}

@Test func irisThreadQueryRequestsAppWideVersionRelationships() throws {
    let url = IrisService.resolutionCenterThreadsURL(appId: "fixture")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(components.path == "/iris/v1/apps/fixture/resolutionCenterThreads")
    #expect(items["include"] == "appStoreVersions,app,appMessageThreadDetail,build,betaBackgroundAssetReviewSubmission")
    #expect(items["limit[appStoreVersions]"] == "2000")
    #expect(items["filter[threadType]"]?.contains("APP_MESSAGE_INFORMATIONAL") == true)
    #expect(items["filter[reviewSubmission]"] == nil)
}

@MainActor @Test func irisFeedbackCannotInventRejectedHeaderForSharedThreadOrOtherPlatform() {
    let manager = ASCManager()
    let ios = feedbackVersion("ios", state: "READY_FOR_SALE")
    let mac = feedbackVersion("mac", "MAC_OS", state: "PREPARE_FOR_SUBMISSION")
    manager.appStoreVersions = [ios, mac]
    var cycle = IrisFeedbackCycle.empty(id: "shared")
    cycle.reasons = [.init(id: "r", section: "Review", description: "Issue", code: "2.1")]
    cycle.appStoreVersionIDs = [ios.id, mac.id]
    manager.irisFeedbackCycles = [cycle]
    #expect(manager.feedbackDisplayVersion(from: [ios]) == nil)
    #expect(manager.feedbackDisplayVersion(from: [mac]) == nil)
    cycle.appStoreVersionIDs = [mac.id]
    manager.irisFeedbackCycles = [cycle]
    manager.rebuildSubmissionHistory(appId: "fixture")
    #expect(manager.feedbackDisplayVersion(from: [ios]) == nil)
    #expect(manager.feedbackDisplayVersion(from: [mac])?.id == mac.id)
}
