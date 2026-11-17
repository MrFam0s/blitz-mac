import Foundation
import Testing
@testable import Blitz

private func submission(_ id: String, _ state: String, _ date: String? = nil) -> ASCReviewSubmission {
    .init(id: id, attributes: .init(state: state, submittedDate: date, platform: "IOS"))
}

private func reviewItem(_ id: String, _ version: String, _ state: String) -> ASCReviewSubmissionItem {
    .init(id: id, attributes: .init(state: state, resolved: nil, createdDate: nil),
          relationships: .init(appStoreVersion: .init(data: .init(type: "appStoreVersions", id: version))))
}

private struct ReviewRefreshFixture: ASCReviewSubmissionDataService {
    var failList = false
    var failItems = false
    func fetchReviewSubmissions(appId: String) async throws -> [ASCReviewSubmission] {
        if failList { throw URLError(.timedOut) }
        return [submission("old", "COMPLETE", "2026-11-16T10:00:00Z"), submission("draft", "READY_FOR_REVIEW")]
    }
    func fetchReviewSubmissionItems(submissionId: String) async throws -> [ASCReviewSubmissionItem] {
        if failItems && submissionId == "draft" { throw URLError(.timedOut) }
        return [reviewItem(submissionId + "-item", "version", submissionId == "draft" ? "READY_FOR_REVIEW" : "ACCEPTED")]
    }
}

private actor ReviewRefreshGate {
    var arrived = false
    var waiting: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    func suspend() async {
        arrived = true
        started?.resume(); started = nil
        await withCheckedContinuation { waiting = $0 }
    }
    func waitUntilStarted() async {
        if !arrived { await withCheckedContinuation { started = $0 } }
    }
    func release() { waiting?.resume(); waiting = nil }
}

private struct DelayedReviewFixture: ASCReviewSubmissionDataService {
    let gate: ReviewRefreshGate?
    let state: String
    func fetchReviewSubmissions(appId: String) async throws -> [ASCReviewSubmission] {
        if let gate { await gate.suspend() }
        return [submission("current", state, "2026-11-17T10:00:00Z")]
    }
    func fetchReviewSubmissionItems(submissionId: String) async throws -> [ASCReviewSubmissionItem] {
        [reviewItem("current-item", "version", state == "UNRESOLVED_ISSUES" ? "REJECTED" : "READY_FOR_REVIEW")]
    }
}

@MainActor struct ASCReviewSubmissionRefreshTests {
    @Test func olderConcurrentRefreshCannotOverwriteNewerReviewState() async {
        let manager = ASCManager(), gate = ReviewRefreshGate()
        let old = Task { await manager.refreshReviewSubmissionData(appId: "app",
            service: DelayedReviewFixture(gate: gate, state: "UNRESOLVED_ISSUES")) }
        await gate.waitUntilStarted()
        await manager.refreshReviewSubmissionData(appId: "app",
            service: DelayedReviewFixture(gate: nil, state: "WAITING_FOR_REVIEW"))
        await gate.release()
        await old.value
        #expect(manager.reviewSubmissionDataComplete)
        #expect(manager.currentReviewSubmission(forVersionId: "version")?.attributes.state == "WAITING_FOR_REVIEW")
    }

    @Test func unknownUndatedStateIsNotHiddenByCompletedHistory() {
        let manager = ASCManager()
        manager.reviewSubmissions = [submission("old", "COMPLETE", "2026-11-16T10:00:00Z"), submission("unknown", "NEW_APPLE_STATE")]
        manager.reviewSubmissionItemsBySubmissionId = ["old": [reviewItem("old-item", "version", "ACCEPTED")],
                                                       "unknown": [reviewItem("new-item", "version", "READY_FOR_REVIEW")]]
        #expect(manager.currentReviewSubmission(forVersionId: "version")?.id == "unknown")
    }
    @Test func undatedDraftRemainsVisibleAheadOfCompletedHistory() async {
        let manager = ASCManager()
        await manager.refreshReviewSubmissionData(appId: "app", service: ReviewRefreshFixture())
        #expect(manager.reviewSubmissionDataComplete)
        #expect(manager.reviewSubmissions.count == 2)
        #expect(manager.currentReviewSubmission(forVersionId: "version")?.id == "draft")
        #expect(manager.latestSubmissionItems(forVersionId: "version").map(\.id) == ["draft-item"])
        manager.rebuildSubmissionHistory(appId: "app")
        #expect(manager.submissionHistoryEvents.filter { $0.eventType == .submitted }.count == 1)
    }

    @Test func failedOrPartialRefreshDoesNotEstablishEmptyOrCompleteReviewState() async {
        for fixture in [ReviewRefreshFixture(failList: true), ReviewRefreshFixture(failItems: true)] {
            let manager = ASCManager()
            manager.reviewSubmissionDataComplete = true
            await manager.refreshReviewSubmissionData(appId: "app", service: fixture)
            #expect(!manager.reviewSubmissionDataComplete)
            #expect(manager.reviewSubmissionItemsBySubmissionId["draft"] == nil)
            manager.resetProjectData(preserveCredentials: true)
            #expect(!manager.reviewSubmissionDataComplete)
        }
    }

    @Test func multipleExactActiveReviewsAreAmbiguousAndOtherVersionsNeverMatch() {
        let manager = ASCManager()
        manager.reviewSubmissions = [submission("one", "UNRESOLVED_ISSUES"), submission("two", "READY_FOR_REVIEW")]
        manager.reviewSubmissionItemsBySubmissionId = ["one": [reviewItem("item1", "version", "REJECTED")],
                                                       "two": [reviewItem("item2", "version", "READY_FOR_REVIEW")]]
        #expect(manager.currentReviewSubmission(forVersionId: "version") == nil)
        #expect(manager.latestSubmissionItems(forVersionId: "version").isEmpty)
        #expect(manager.currentReviewSubmission(forVersionId: "another-platform-version") == nil)
    }

    @Test func completeReviewCollectionsFollowPaginationIncludingUndatedDraft() async throws {
        let service = AppStoreConnectService(requestTransport: { method, path, _, _ in
            #expect(method == "GET")
            let second = path.contains("cursor=next")
            let body = second
                ? #"{"data":[{"id":"draft","attributes":{"state":"READY_FOR_REVIEW","platform":"IOS"}}]}"#
                : #"{"data":[{"id":"old","attributes":{"state":"COMPLETE","submittedDate":"2026-11-16T10:00:00Z","platform":"IOS"}}],"links":{"next":"https://api.appstoreconnect.apple.com/v1/reviewSubmissions?cursor=next&filter%5Bapp%5D=app"}}"#
            return .init(statusCode: 200, headers: [:], contentType: "application/json", body: Data(body.utf8))
        })
        #expect(try await service.fetchReviewSubmissions(appId: "app").map(\.id) == ["draft", "old"])
    }

    @Test func reviewPaginationCannotChangeAppScope() async {
        let service = AppStoreConnectService(requestTransport: { _, _, _, _ in
            .init(statusCode: 200, headers: [:], contentType: "application/json", body: Data(#"{"data":[],"links":{"next":"https://api.appstoreconnect.apple.com/v1/reviewSubmissions?filter%5Bapp%5D=foreign"}}"#.utf8))
        })
        await #expect(throws: (any Error).self) { try await service.fetchReviewSubmissions(appId: "app") }
    }
}
