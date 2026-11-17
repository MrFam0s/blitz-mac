import Foundation
import Testing
@testable import Blitz

private let archiveThreadURL = "https://appstoreconnect.apple.com/iris/v1/apps/test-app/resolutionCenterThreads"
private let archiveMessageURL = "https://appstoreconnect.apple.com/iris/v1/resolutionCenterThreads/thread-test/resolutionCenterMessages"

private func archivePage(_ url: String, data: [[String: Any]], included: [[String: Any]] = []) throws -> IrisRawPage {
    IrisRawPage(url: url, data: try JSONSerialization.data(withJSONObject: ["data": data, "included": included], options: [.sortedKeys]))
}

private func archiveMessage(_ id: String, body: String, actor: String? = "APPLE", date: String = "2026-11-17T10:00:00Z") -> [String: Any] {
    var message: [String: Any] = ["id": id, "type": "resolutionCenterMessages",
        "attributes": ["messageBody": body, "createdDate": date]]
    if let actor {
        message["relationships"] = ["fromActor": ["data": ["type": "actors", "id": actor]]]
    }
    return message
}

private func archiveThread(versionIDs: [String]? = nil, submission: String? = nil) -> [String: Any] {
    var relationships: [String: Any] = [:]
    if let versionIDs {
        relationships["appStoreVersions"] = ["data": versionIDs.map { ["type": "appStoreVersions", "id": $0] }]
    }
    if let submission {
        relationships["reviewSubmission"] = ["data": ["type": "reviewSubmissions", "id": submission]]
    }
    return ["id": "thread-test", "type": "resolutionCenterThreads",
            "attributes": ["createdDate": "2026-11-17T09:00:00Z"], "relationships": relationships]
}

@Suite @MainActor
struct IrisArchiveProjectionTests {
    @Test func messagesWithoutEnglishVersionMarkerKeepBothSenders() throws {
        let question = archiveMessage("question", body: "<p>Please explain the drawing feature.</p>")
        let reply = archiveMessage("reply", body: "<p>The drawings stay on the device.</p>", actor: "USER:test", date: "2026-11-17T11:00:00Z")
        let rejection: [String: Any] = ["id": "reason", "type": "reviewRejections",
            "attributes": ["reasons": [["reasonSection": "Information Needed", "reasonDescription": "Please reply.", "reasonCode": "2.1"]]]]
        let projection = try IrisArchiveStore.project(appId: "test-app", pages: [
            archivePage(archiveThreadURL, data: [archiveThread()]),
            archivePage(archiveMessageURL, data: [reply, question], included: [rejection])
        ])
        let cycle = try #require(projection.cycles.first)
        #expect(cycle.versionString == nil)
        #expect(cycle.submissionId == nil)
        #expect(cycle.messages.map(\.id) == ["question", "reply"])
        #expect(cycle.messages.map(\.sender) == [.apple, .developer])
        #expect(cycle.reasons.count == 1)
        #expect(cycle.reviewerMessage == "Please explain the drawing feature.")
    }

    @Test func structuredVersionAndSubmissionIdentitySurviveSnapshots() throws {
        let projection = try IrisArchiveStore.project(appId: "test-app", pages: [
            archivePage(archiveThreadURL, data: [archiveThread(versionIDs: ["ios-v1"], submission: "actual-submission")]),
            archivePage(archiveMessageURL, data: [archiveMessage("question", body: "<p>Version reviewed: 1.2.1</p><p>Submission ID: text-only-id</p>")]),
            archivePage(archiveThreadURL + "?include=appStoreVersions", data: [archiveThread(versionIDs: ["mac-v1", "ios-v1"], submission: "actual-submission")])
        ])
        let cycle = try #require(projection.cycles.first)
        #expect(cycle.appStoreVersionIDs == ["ios-v1", "mac-v1"])
        #expect(cycle.submissionId == "actual-submission")
        #expect(cycle.versionString == "1.2.1")
    }

    @Test func conversationsAcrossReviewRoundsDoNotChooseFirstVersion() throws {
        let projection = try IrisArchiveStore.project(appId: "test-app", pages: [
            archivePage(archiveMessageURL, data: [
                archiveMessage("old", body: "<p>Version reviewed: 1.0.3</p><p>Submission ID: old</p>"),
                archiveMessage("new", body: "<p>Version reviewed: 1.2.1</p><p>Submission ID: new</p>", date: "2026-11-17T12:00:00Z")
            ])
        ])
        let cycle = try #require(projection.cycles.first)
        #expect(cycle.versionString == nil)
        #expect(cycle.submissionId == nil)
        #expect(cycle.messages.count == 2)
    }

    @Test func developerAndUnknownActorCannotEstablishReviewIdentity() throws {
        let projection = try IrisArchiveStore.project(appId: "test-app", pages: [
            archivePage(archiveMessageURL, data: [
                archiveMessage("developer", body: "<p>Version reviewed: 1.2.1</p><p>Submission ID: guessed</p>", actor: "USER:test"),
                archiveMessage("legacy", body: "<p>Version reviewed: 1.2.1</p>", actor: nil),
                archiveMessage("unknown", body: "<p>Version reviewed: 1.2.1</p>", actor: "OTHER")
            ])
        ])
        let cycle = try #require(projection.cycles.first)
        #expect(cycle.versionString == nil)
        #expect(cycle.submissionId == nil)
        #expect(cycle.messages.first(where: { $0.id == "developer" })?.sender == .developer)
        #expect(cycle.messages.first(where: { $0.id == "legacy" })?.sender == .unknown)
        #expect(cycle.messages.first(where: { $0.id == "unknown" })?.sender == .unknown)
    }

    @Test func repeatedIdenticalAppleMarkersAreUnambiguous() throws {
        let projection = try IrisArchiveStore.project(appId: "test-app", pages: [
            archivePage(archiveMessageURL, data: [
                archiveMessage("first", body: "<p>Version reviewed: 1.2.1</p>"),
                archiveMessage("second", body: "<p>version reviewed: 1.2.1</p>")
            ])
        ])
        #expect(projection.cycles.first?.versionString == "1.2.1")
    }

    @Test func paginationAndNewerEmptySnapshotPreserveRichMessage() throws {
        let projection = try IrisArchiveStore.project(appId: "test-app", pages: [
            archivePage(archiveMessageURL, data: [archiveMessage("first", body: "Original question", actor: nil)]),
            archivePage(archiveMessageURL + "?cursor=next", data: [archiveMessage("second", body: "Our reply", actor: "USER:test")]),
            archivePage(archiveMessageURL, data: [archiveMessage("first", body: "", date: "2026-11-17T13:00:00Z")])
        ])
        let cycle = try #require(projection.cycles.first)
        #expect(cycle.messages.count == 2)
        let first = try #require(cycle.messages.first(where: { $0.id == "first" }))
        #expect(first.body == "Original question")
        #expect(first.sender == .apple)
        #expect(cycle.blobHashes.count == 3)
    }

    @Test(arguments: ["thread", "message", "rejection"])
    func malformedPagesDoNotBecomeEmptySuccess(kind: String) throws {
        let page: IrisRawPage
        switch kind {
        case "thread":
            page = try archivePage(archiveThreadURL, data: [["id": "bad", "attributes": "invalid"]])
        case "message":
            page = try archivePage(archiveMessageURL, data: [["id": "bad", "attributes": ["messageBody": 123]]])
        default:
            page = try archivePage(archiveMessageURL, data: [], included: [["id": "bad", "type": "reviewRejections", "attributes": ["reasons": "invalid"]]])
        }
        #expect(throws: (any Error).self) {
            _ = try IrisArchiveStore.project(appId: "test-app", pages: [page])
        }
    }

    @Test func legacyProjectionDecodesButRequestsRebuild() throws {
        let raw = Data(#"{"appId":"test-app","lastRebuiltAt":"2026-11-16T00:00:00Z","cycles":[{"id":"thread-test","occurredAt":"2026-11-16T00:00:00Z","messages":[{"id":"legacy","body":"Existing body"}],"reasons":[],"source":"archive","blobHashes":[]}] }"#.utf8)
        let old = try JSONDecoder().decode(IrisFeedbackProjection.self, from: raw)
        #expect(old.needsRebuild)
        #expect(old.schemaVersion == nil)
        #expect(old.cycles.first?.messages.first?.sender == nil)
        #expect(old.cycles.first?.appStoreVersionIDs == nil)
        let current = try IrisArchiveStore.project(appId: "test-app", pages: [
            archivePage(archiveMessageURL, data: [archiveMessage("legacy", body: "Existing body")])
        ])
        let decoded = try JSONDecoder().decode(IrisFeedbackProjection.self, from: JSONEncoder().encode(current))
        #expect(!decoded.needsRebuild)
        #expect(decoded.cycles.first?.messages.first?.sender == .apple)
    }

    @Test func failedLegacyMigrationKeepsContentWithoutUnverifiedTargetClaims() throws {
        var cycle = IrisFeedbackCycle.empty(id: "legacy-thread", occurredAt: "2026-11-16T00:00:00Z")
        cycle.versionString = "1.2.1"
        cycle.submissionId = "unverified-text-id"
        cycle.appStoreVersionIDs = ["unverified-version-id"]
        cycle.messages = [.init(id: "message", body: "Existing conversation", createdAt: "2026-11-16T00:00:00Z", sender: .apple)]
        cycle.reasons = [.init(id: "reason", section: "Information Needed", description: "Original reason", code: "2.1")]
        let old = IrisFeedbackProjection(appId: "test-app", cycles: [cycle], lastRebuiltAt: "2026-11-16T00:00:00Z", schemaVersion: nil)
        let fallback = old.unassignedLegacyFallback
        let retained = try #require(fallback.cycles.first)
        #expect(fallback.needsRebuild)
        #expect(fallback.schemaVersion == nil)
        #expect(fallback.appId == old.appId && fallback.lastRebuiltAt == old.lastRebuiltAt)
        #expect(retained.versionString == nil && retained.submissionId == nil && retained.appStoreVersionIDs == nil)
        #expect(retained.messages.first?.body == "Existing conversation")
        #expect(retained.messages.first?.sender == .unknown)
        #expect(retained.reasons.first?.description == "Original reason")

        let current = IrisFeedbackProjection(appId: "test-app", cycles: [cycle], lastRebuiltAt: "2026-11-17T00:00:00Z")
        #expect(current.unassignedLegacyFallback.cycles.first?.appStoreVersionIDs == ["unverified-version-id"])
        #expect(current.unassignedLegacyFallback.cycles.first?.messages.first?.sender == .apple)
    }
}
