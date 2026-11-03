import Foundation
import Testing
@testable import Blitz

private actor DetailGate {
    private var started = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        arrival?.resume(); arrival = nil
        await withCheckedContinuation { result = $0 }
    }
    func entered() async { if !started { await withCheckedContinuation { arrival = $0 } } }
    func release() { result?.resume(); result = nil }
}

@MainActor @Test func testFlightDetailCacheRejectsLateScopeAndKeepsNewLoad() async {
    let cache = ASCTestFlightDetailCache<String>()
    let gate = DetailGate()
    var generation = 0
    let old = Task {
        await cache.refresh(id: "build", force: true, isCurrent: { generation == 0 }) {
            await gate.wait()
            return "old app"
        }
    }
    await gate.entered()
    generation = 1
    #expect(await cache.refresh(id: "build", force: true, isCurrent: { generation == 1 }) { "new app" })
    await gate.release()
    #expect(!(await old.value))
    #expect(cache.values["build"] == "new app")
    #expect(cache.loading.isEmpty)
}

@MainActor @Test func testFlightDetailCacheResetRejectsLateTesterData() async {
    let cache = ASCTestFlightDetailCache<[String]>()
    let gate = DetailGate()
    let task = Task {
        await cache.refresh(id: "group", force: true, isCurrent: { true }) {
            await gate.wait()
            return ["private@example.com"]
        }
    }
    await gate.entered()
    cache.reset()
    await gate.release()
    #expect(!(await task.value))
    #expect(cache.values.isEmpty)
    #expect(cache.loading.isEmpty)
    #expect(cache.errors.isEmpty)
}

@MainActor @Test func testFlightDetailCacheKeepsConfirmedDataOnFailureAndBoundsMemory() async {
    let cache = ASCTestFlightDetailCache<[String]>(capacity: 2)
    #expect(await cache.refresh(id: "a", force: true, isCurrent: { true }) { ["tester"] })
    #expect(!(await cache.refresh(id: "a", force: true, isCurrent: { true }) { throw URLError(.timedOut) }))
    #expect(cache.values["a"] == ["tester"])
    #expect(cache.errors["a"] != nil)
    #expect(!(await cache.refresh(id: "b", force: true, isCurrent: { true }) { throw URLError(.timedOut) }))
    #expect(cache.values["b"] == nil) // Failure is not a confirmed empty relation.
    #expect(await cache.refresh(id: "c", force: true, isCurrent: { true }) { [] })
    #expect(cache.values["a"] == nil)
    #expect(cache.errors["a"] == nil)
    #expect(cache.values["c"]?.isEmpty == true)
    cache.retain(ids: ["c"])
    #expect(cache.errors["b"] == nil)
}

@MainActor @Test func testFlightDetailCacheCoalescesAndRevalidatesChangedScope() async {
    let cache = ASCTestFlightDetailCache<String>()
    var calls = 0
    var revision = 0
    #expect(await cache.refresh(id: "build", force: true, isCurrent: { revision == 0 }) { calls += 1; return "first" })
    #expect(await cache.refresh(id: "build", force: false, isCurrent: { revision == 0 }) { calls += 1; return "unexpected" })
    #expect(calls == 1)
    revision = 1
    #expect(await cache.refresh(id: "build", force: false, isCurrent: { revision == 1 }) { calls += 1; return "second" })
    #expect(calls == 2)
    #expect(cache.values["build"] == "second")
}

private func detailDecode<T: Decodable>(_ json: String, as: T.Type = T.self) -> T {
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private struct DetailFixture: ASCTestFlightService {
    var returnedApp = "app-a"
    var feedbackFails = false
    func fetchBuilds(appId: String) async throws -> [ASCBuild] { [] }
    func fetchBetaGroups(appId: String) async throws -> [ASCBetaGroup] { [] }
    func fetchBetaLocalizations(appId: String) async throws -> [ASCBetaLocalization] { [] }
    func fetchBetaFeedback(appId: String, buildId: String) async throws -> [ASCBetaFeedback] {
        if feedbackFails { throw URLError(.timedOut) }
        return []
    }
    func fetchTestFlightBuildDetail(appId: String, buildId: String) async throws -> ASCTestFlightBuildDetail {
        let build: ASCBuild = detailDecode("""
        {"id":"\(buildId)","attributes":{"version":"7"},"relationships":{"app":{"data":{"id":"\(returnedApp)"}}}}
        """)
        return ASCTestFlightBuildDetail(build: build, betaGroups: [], individualTesters: [])
    }
    func fetchTestFlightGroupDetail(appId: String, groupId: String) async throws -> ASCTestFlightGroupDetail {
        let group: ASCBetaGroup = detailDecode("""
        {"id":"\(groupId)","attributes":{"name":"Group"},"relationships":{"app":{"data":{"id":"\(returnedApp)"}}}}
        """)
        return ASCTestFlightGroupDetail(group: group, builds: [], testers: [])
    }
}

@MainActor @Test func testFlightDetailsValidateAppAndDoNotChangeSelection() async {
    let manager = ASCManager()
    manager.app = detailDecode(#"{"id":"app-a","attributes":{"name":"A","bundleId":"org.example.a"}}"#)
    manager.selectedTestFlightBuildId = "selected-build"
    manager.selectedTestFlightGroupId = "selected-group"
    #expect(await manager.refreshTestFlightBuildDetail(buildId: "queried-build", using: DetailFixture()))
    #expect(await manager.refreshTestFlightGroupDetail(groupId: "queried-group", using: DetailFixture()))
    #expect(manager.selectedTestFlightBuildId == "selected-build")
    #expect(manager.selectedTestFlightGroupId == "selected-group")
    #expect(!(await manager.refreshTestFlightBuildDetail(buildId: "wrong-build", using: DetailFixture(returnedApp: "app-b"))))
    #expect(!(await manager.refreshTestFlightGroupDetail(groupId: "wrong-group", using: DetailFixture(returnedApp: "app-b"))))
    #expect(manager.testFlightBuildDetails["wrong-build"] == nil)
    #expect(manager.testFlightGroupDetails["wrong-group"] == nil)
    #expect(manager.testFlightBuildErrors["wrong-build"] != nil)
    #expect(manager.testFlightGroupErrors["wrong-group"] != nil)
}

@Test func testFlightLabelsDistinguishBuildTrainPlatformAndUnknownStates() {
    var ios: ASCBuild = detailDecode(#"{"id":"ios","attributes":{"version":"7","processingState":"VALID"}}"#)
    ios.preReleaseVersion = detailDecode(#"{"id":"train","attributes":{"version":"2.0","platform":"IOS"}}"#)
    var mac = ios
    mac.preReleaseVersion = detailDecode(#"{"id":"other","attributes":{"version":"3.0","platform":"MAC_OS"}}"#)
    #expect(TestFlightPresentation.buildLabel(ios) == "2.0 (7) · iOS")
    #expect(TestFlightPresentation.buildLabel(mac) == "3.0 (7) · macOS")
    #expect(TestFlightPresentation.status(nil) == "Not available")
    #expect(TestFlightPresentation.expiration(ios) == "Not available")
    let expired: ASCBuild = detailDecode(#"{"id":"old","attributes":{"version":"7","expired":false,"expirationDate":"2020-01-01T00:00:00Z"}}"#)
    #expect(TestFlightPresentation.expiration(expired, now: Date(timeIntervalSince1970: 1_700_000_000)) == "Expired")
    let unknownGroup: ASCBetaGroup = detailDecode(#"{"id":"g","attributes":{"name":"Group"}}"#)
    #expect(TestFlightPresentation.groupType(unknownGroup) == "Type unknown")
}

@MainActor @Test func testFlightCachedFeedbackDoesNotDisplayAnotherBuildsFailure() async {
    let manager = ASCManager()
    manager.app = detailDecode(#"{"id":"app-a","attributes":{"name":"A","bundleId":"org.example.a"}}"#)
    manager.selectedBuildId = "build-b"
    #expect(await manager.refreshBetaFeedback(buildId: "build-b", using: DetailFixture()))
    manager.selectedBuildId = "build-a"
    #expect(await manager.refreshBetaFeedback(buildId: "build-a", using: DetailFixture()))
    #expect(!(await manager.refreshBetaFeedback(buildId: "build-a", using: DetailFixture(feedbackFails: true))))
    #expect(manager.tabError[.feedback] != nil)
    // Revisiting A's confirmed data must retain A's failed-refresh warning.
    #expect(await manager.refreshBetaFeedback(buildId: "build-a", force: false, using: DetailFixture()))
    #expect(manager.tabError[.feedback] != nil)
    manager.selectedBuildId = "build-b"
    #expect(await manager.refreshBetaFeedback(buildId: "build-b", force: false, using: DetailFixture(feedbackFails: true)))
    #expect(manager.betaFeedback["build-b"]?.isEmpty == true)
    #expect(manager.tabError[.feedback] == nil)
}
