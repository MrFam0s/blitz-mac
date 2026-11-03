import Foundation
import Testing
@testable import Blitz

private actor IrisReplyGate {
    private var entered = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var reply: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        arrival?.resume(); arrival = nil
        if !released { await withCheckedContinuation { reply = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { arrival = $0 } }
    }
    func release() {
        released = true
        reply?.resume(); reply = nil
    }
}

private struct IrisReplyFixture: IrisFeedbackService {
    let gate: IrisReplyGate
    var expiresSession = false

    func fetchResolutionCenterThreadPages(appId: String) async throws -> [IrisRawPage] {
        await gate.wait() // Deliberately return even when the task was cancelled.
        if expiresSession { throw IrisError.sessionExpired }
        return []
    }
    func fetchMessagesAndRejectionsPages(threadId: String) async throws -> [IrisRawPage] { [] }
}

private enum IrisTargetChange: CaseIterable { case project, version, account }

@MainActor
private func irisRaceManager() throws -> ASCManager {
    let manager = ASCManager()
    manager.loadedProjectId = "project-a"
    manager.app = try JSONDecoder().decode(ASCApp.self, from: Data(#"{"id":"app-a","attributes":{"name":"A","bundleId":"org.example.a"}}"#.utf8))
    manager.selectedVersionId = "version-a"
    manager.irisSessionState = .valid
    return manager
}

@MainActor
@Test(arguments: IrisTargetChange.allCases, [false, true])
private func irisLateReplyCannotReplaceCurrentFeedbackOrExpireItsSession(change: IrisTargetChange, expiresSession: Bool) async throws {
    let manager = try irisRaceManager()
    let gate = IrisReplyGate()
    let task = Task { await manager.fetchRejectionFeedback(force: true, using: IrisReplyFixture(gate: gate, expiresSession: expiresSession)) }
    await gate.waitUntilEntered()

    switch change {
    case .project:
        manager.resetProjectData(preserveCredentials: true)
        manager.loadedProjectId = "project-b"
        manager.app = try JSONDecoder().decode(ASCApp.self, from: Data(#"{"id":"app-b","attributes":{"name":"B","bundleId":"org.example.b"}}"#.utf8))
    case .version:
        // Also cover a direct selection change without a revision/cancellation.
        manager.selectedVersionId = "version-b"
    case .account:
        manager.credentials = ASCCredentials(issuerId: "new-issuer", keyId: "new-key", privateKey: "unused")
    }
    manager.resolutionCenterThreads = [IrisResolutionCenterThread(id: "current-thread", attributes: .init(state: nil, createdDate: nil, lastMessageResponseDate: nil))]
    manager.irisFeedbackError = "current-error"
    manager.isLoadingIrisFeedback = true
    manager.irisSessionState = .valid
    await gate.release()
    await task.value

    #expect(manager.resolutionCenterThreads.map(\.id) == ["current-thread"])
    #expect(manager.irisFeedbackError == "current-error")
    #expect(manager.isLoadingIrisFeedback)
    #expect(manager.irisSessionState == .valid)
    #expect(manager.irisLastFetchedAtByAppId["app-a"] == nil)
}

@MainActor
@Test func irisOldRequestCleanupCannotRemoveANewRequestForTheSameApp() async throws {
    let manager = try irisRaceManager()
    let oldGate = IrisReplyGate()
    let oldTask = Task { await manager.fetchRejectionFeedback(force: true, using: IrisReplyFixture(gate: oldGate)) }
    await oldGate.waitUntilEntered()
    manager.resetProjectData(preserveCredentials: true)
    manager.loadedProjectId = "project-a"
    manager.app = try JSONDecoder().decode(ASCApp.self, from: Data(#"{"id":"app-a","attributes":{"name":"A","bundleId":"org.example.a"}}"#.utf8))
    let newGate = IrisReplyGate()
    let newTask = Task { await manager.fetchRejectionFeedback(force: true, using: IrisReplyFixture(gate: newGate)) }
    await newGate.waitUntilEntered()
    let newID = manager.irisFetchRequestIDsByAppId["app-a"]
    await oldGate.release()
    await oldTask.value

    #expect(manager.irisFetchRequestIDsByAppId["app-a"] == newID)
    #expect(manager.irisFetchTasksByAppId["app-a"] != nil)
    #expect(manager.isLoadingIrisFeedback)

    manager.cancelIrisFeedbackLoads()
    await newGate.release()
    await newTask.value
    #expect(manager.irisFetchTasksByAppId.isEmpty)
    #expect(!manager.isLoadingIrisFeedback)
}
