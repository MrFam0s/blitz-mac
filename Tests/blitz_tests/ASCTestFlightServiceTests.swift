import Foundation
import Testing
@testable import Blitz

private actor TestFlightRequests {
    struct Request {
        let method: String
        let path: String
        let body: Data?
        var components: URLComponents { URLComponents(string: path)! }
        var query: [String: String] {
            Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        }
    }
    var requests: [Request] = []
    var replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func request(_ method: String, _ path: String, _ headers: [String: String], _ body: Data?) throws -> ASCDaemonClient.HTTPResponse {
        let request = Request(method: method, path: path, body: body)
        requests.append(request)
        // Apple's betaGroups endpoint rejects app + builds relationship filters,
        // even though both are individually listed by its OpenAPI schema.
        if method == "GET", request.components.path == "/v1/betaGroups",
           request.query["filter[app]"] != nil, request.query["filter[builds]"] != nil {
            let error = #"{"errors":[{"status":"400","detail":"Only one relationship filter can be applied."}]}"#
            return .init(statusCode: 400, headers: [:], contentType: "application/json", body: Data(error.utf8))
        }
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        return .init(statusCode: 200, headers: [:], contentType: "application/json", body: Data(replies.removeFirst().utf8))
    }
    nonisolated func service() -> AppStoreConnectService {
        AppStoreConnectService(requestTransport: { try await self.request($0, $1, $2, $3) })
    }
}

private func flightGroup(_ id: String, app: String = "app-a") -> String {
    #"{"id":"\#(id)","type":"betaGroups","attributes":{"name":"\#(id)","isInternalGroup":false},"relationships":{"app":{"data":{"type":"apps","id":"\#(app)"}}}}"#
}
private func flightBuild(_ id: String, app: String = "app-a") -> String {
    #"{"id":"\#(id)","type":"builds","attributes":{"version":"42","processingState":"VALID","expired":false},"relationships":{"app":{"data":{"type":"apps","id":"\#(app)"}},"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"train"}},"buildBetaDetail":{"data":{"type":"buildBetaDetails","id":"beta"}}}}"#
}
private let flightIncluded = #"[{"type":"apps","id":"app-a","attributes":{}},{"type":"preReleaseVersions","id":"train","attributes":{"version":"2.1","platform":"MAC_OS"}},{"type":"buildBetaDetails","id":"beta","attributes":{"internalBuildState":"IN_BETA_TESTING","externalBuildState":"WAITING_FOR_BETA_REVIEW","autoNotifyEnabled":false}},{"type":"buildBetaDetails","id":"other","attributes":{"externalBuildState":"BETA_APPROVED"}}]"#

@Test func testFlightCollectionsFollowEveryPageAndRetainScope() async throws {
    for kind in ["groups", "localizations", "feedback"] {
        let path: String
        let first: String
        let second: String
        switch kind {
        case "groups":
            path = "/v1/apps/app-a/betaGroups"
            first = flightGroup("group-a"); second = flightGroup("group-b")
        case "localizations":
            path = "/v1/apps/app-a/betaAppLocalizations"
            first = #"{"id":"loc-a","attributes":{"locale":"de-DE"}}"#
            second = #"{"id":"loc-b","attributes":{"locale":"en-US"}}"#
        default:
            path = "/v1/apps/app-a/betaFeedbackScreenshotSubmissions"
            first = #"{"id":"feedback-a","attributes":{"comment":"First"}}"#
            second = #"{"id":"feedback-b","attributes":{"comment":"Second"}}"#
        }
        let next = kind == "localizations" ? "?cursor=page2" : "https://api.appstoreconnect.apple.com\(path)?cursor=page2"
        let transport = TestFlightRequests([
            #"{"data":[\#(first)],"links":{"next":"\#(next)"}}"#,
            #"{"data":[\#(first),\#(second)],"links":{"next":null}}"#
        ])
        let service = transport.service()
        let count: Int
        switch kind {
        case "groups": count = try await service.fetchBetaGroups(appId: "app-a").count
        case "localizations": count = try await service.fetchBetaLocalizations(appId: "app-a").count
        default: count = try await service.fetchBetaFeedback(appId: "app-a", buildId: "build-a").count
        }
        #expect(count == 2)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.method == "GET" && $0.components.path == path })
        #expect(requests[1].query["cursor"] == "page2")
        #expect(requests[1].query["limit"] == "200")
        if kind == "feedback" { #expect(requests.allSatisfy { $0.query["filter[build]"] == "build-a" }) }
    }
}

@Test func testFlightBuildDetailLoadsAppScopedGroupsAndIndividualTesters() async throws {
    let transport = TestFlightRequests([
        #"{"data":\#(flightBuild("build-a")),"included":\#(flightIncluded)}"#,
        #"{"data":[\#(flightGroup("group-a"))],"links":{"next":"/v1/betaGroups?cursor=next"}}"#,
        #"{"data":[\#(flightGroup("group-b"))]}"#,
        #"{"data":[{"id":"tester-a","attributes":{"email":"tester@example.com","state":"ACCEPTED","inviteType":"EMAIL"}}],"links":{"next":"/v1/builds/build-a/individualTesters?cursor=next"}}"#,
        #"{"data":[{"id":"anonymous","attributes":null}]}"#
    ])
    let detail = try await transport.service().fetchTestFlightBuildDetail(appId: "app-a", buildId: "build-a")
    #expect(detail.build.preReleaseVersion?.attributes.platform == "MAC_OS")
    #expect(detail.build.preReleaseVersion?.attributes.version == "2.1")
    #expect(detail.build.buildBetaDetail?.internalBuildState == "IN_BETA_TESTING")
    #expect(detail.build.buildBetaDetail?.externalBuildState == "WAITING_FOR_BETA_REVIEW")
    #expect(detail.betaGroups.map(\.id) == ["group-a", "group-b"])
    #expect(detail.individualTesters.map(\.id) == ["tester-a", "anonymous"])
    #expect(detail.individualTesters.last?.attributes.email == nil)
    let requests = await transport.requests
    #expect(requests.count == 5)
    #expect(requests[0].components.path == "/v1/builds/build-a")
    for request in requests[1...2] {
        #expect(request.components.path == "/v1/betaGroups")
        #expect(request.query["filter[app]"] == nil)
        #expect(request.query["filter[builds]"] == "build-a")
    }
    #expect(requests[3].components.path == "/v1/builds/build-a/individualTesters")
}

@Test func testFlightGroupDetailLoadsHydratedBuildsAndAllTesterPages() async throws {
    let transport = TestFlightRequests([
        #"{"data":\#(flightGroup("group-a"))}"#,
        #"{"data":[\#(flightBuild("build-a"))],"included":\#(flightIncluded),"links":{"next":"/v1/builds?cursor=next"}}"#,
        #"{"data":[\#(flightBuild("build-b"))],"included":\#(flightIncluded)}"#,
        #"{"data":[{"id":"tester-a","attributes":{"firstName":"Alice"}}],"links":{"next":"/v1/betaGroups/group-a/betaTesters?cursor=next"}}"#,
        #"{"data":[{"id":"tester-b","attributes":{"inviteType":"PUBLIC_LINK"}}]}"#
    ])
    let detail = try await transport.service().fetchTestFlightGroupDetail(appId: "app-a", groupId: "group-a")
    #expect(detail.group.id == "group-a")
    #expect(detail.builds.map(\.id) == ["build-a", "build-b"])
    #expect(detail.builds.allSatisfy { $0.preReleaseVersion?.attributes.version == "2.1" })
    #expect(detail.builds.allSatisfy { $0.buildBetaDetail?.externalBuildState == "WAITING_FOR_BETA_REVIEW" })
    #expect(detail.testers.map(\.id) == ["tester-a", "tester-b"])
    let requests = await transport.requests
    #expect(requests.count == 5)
    #expect(requests[0].components.path == "/v1/betaGroups/group-a")
    #expect(requests[0].query["include"] == "app")
    for request in requests[1...2] {
        #expect(request.components.path == "/v1/builds")
        #expect(request.query["filter[app]"] == "app-a")
        #expect(request.query["filter[betaGroups]"] == "group-a")
        #expect(request.query["include"]?.contains("buildBetaDetail") == true)
    }
    #expect(requests[3].components.path == "/v1/betaGroups/group-a/betaTesters")
}

@Test func testFlightDetailsRejectWrongParentBeforeLoadingAssociations() async throws {
    for kind in ["buildApp", "buildID", "groupApp", "groupID"] {
        let isBuild = kind.hasPrefix("build")
        let resource = isBuild
            ? flightBuild(kind == "buildID" ? "other" : "build-a", app: kind == "buildApp" ? "app-b" : "app-a")
            : flightGroup(kind == "groupID" ? "other" : "group-a", app: kind == "groupApp" ? "app-b" : "app-a")
        let transport = TestFlightRequests([#"{"data":\#(resource)}"#])
        do {
            if isBuild { _ = try await transport.service().fetchTestFlightBuildDetail(appId: "app-a", buildId: "build-a") }
            else { _ = try await transport.service().fetchTestFlightGroupDetail(appId: "app-a", groupId: "group-a") }
            Issue.record("Mismatched parent must not expose associations: \(kind)")
        } catch is ASCError { }
        #expect(await transport.requests.count == 1)
    }
}

@Test func testFlightPaginationRejectsScopeOriginEndpointAndCycles() async throws {
    let paths = [
        "https://example.com/v1/apps/app-a/betaGroups?cursor=next",
        "/v1/apps/app-b/betaGroups?cursor=next",
        "/v1/apps/app-a/betaGroups?limit=200"
    ]
    for next in paths {
        let transport = TestFlightRequests([#"{"data":[],"links":{"next":"\#(next)"}}"#])
        do {
            _ = try await transport.service().fetchBetaGroups(appId: "app-a")
            Issue.record("Invalid pagination must fail: \(next)")
        } catch is ASCError { }
        #expect(await transport.requests.count == 1)
    }
    let transport = TestFlightRequests([
        #"{"data":\#(flightBuild("build-a"))}"#,
        #"{"data":[],"links":{"next":"/v1/betaGroups?filter%5Bbuilds%5D=other&cursor=next"}}"#
    ])
    do {
        _ = try await transport.service().fetchTestFlightBuildDetail(appId: "app-a", buildId: "build-a")
        Issue.record("A next page must not change the build filter")
    } catch is ASCError { }
    #expect(await transport.requests.count == 2)
}

@Test func testFlightRelationsRejectOtherAppResources() async throws {
    let cases = [
        [#"{"data":\#(flightBuild("build-a"))}"#, #"{"data":[\#(flightGroup("foreign", app: "app-b"))]}"#],
        [#"{"data":\#(flightGroup("group-a"))}"#, #"{"data":[\#(flightBuild("foreign", app: "app-b"))]}"#]
    ]
    for (index, replies) in cases.enumerated() {
        let transport = TestFlightRequests(replies)
        do {
            if index == 0 { _ = try await transport.service().fetchTestFlightBuildDetail(appId: "app-a", buildId: "build-a") }
            else { _ = try await transport.service().fetchTestFlightGroupDetail(appId: "app-a", groupId: "group-a") }
            Issue.record("Foreign app resources must fail closed")
        } catch is ASCError { }
        #expect(await transport.requests.count == 2)
    }
}

@Test func betaLocalizationPatchClearsOnlyExplicitFieldsWithNull() async throws {
    let transport = TestFlightRequests([#"{}"#])
    try await transport.service().patchBetaLocalization(id: "loc-a", fields: ["description": "New text", "feedbackEmail": "", "marketingUrl": ""])
    let requests = await transport.requests
    let request = try #require(requests.first)
    #expect(request.method == "PATCH")
    #expect(request.components.path == "/v1/betaAppLocalizations/loc-a")
    let body = try #require(request.body)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let data = try #require(payload["data"] as? [String: Any])
    let fields = try #require(data["attributes"] as? [String: Any])
    #expect(fields["description"] as? String == "New text")
    #expect(fields["feedbackEmail"] is NSNull)
    #expect(fields["marketingUrl"] is NSNull)
    #expect(fields["privacyPolicyUrl"] == nil)
    try await transport.service().patchBetaLocalization(id: "loc-a", fields: [:])
    do {
        try await transport.service().patchBetaLocalization(id: "loc-a", fields: ["locale": "de-DE"])
        Issue.record("Unsupported beta fields must be rejected")
    } catch is ASCError { }
    #expect(await transport.requests.count == 1)
}

@Test func privateTestFlightBodiesAreExcludedFromLogsWhileUIErrorsRemainAvailable() async throws {
    let privateBody = Data(#"{"email":"PRIVATE-TESTER","comment":"PRIVATE-COMMENT"}"#.utf8)
    for path in ["/v1/betaGroups/g/betaTesters", "/v1/builds/b/individualTesters", "/v1/apps/a/betaFeedbackScreenshotSubmissions", "/v1/betaFeedbackCrashSubmissions/f", "/v1/builds?include=app,individualTesters"] {
        #expect(ASCTestFlightPrivacy.shouldRedact(path: path))
        #expect(!String(decoding: ASCTestFlightPrivacy.bodyForLogging(privateBody, path: path), as: UTF8.self).contains("PRIVATE"))
    }
    #expect(ASCTestFlightPrivacy.bodyForLogging(privateBody, path: "/v1/apps/a/betaGroups") == privateBody)
    let service = AppStoreConnectService(requestTransport: { _, _, _, _ in
        .init(statusCode: 403, headers: [:], contentType: "application/json", body: privateBody)
    })
    do {
        _ = try await service.fetchBetaFeedback(appId: "app-a", buildId: "build-a")
        Issue.record("403 must be propagated")
    } catch {
        #expect(error.localizedDescription.contains("PRIVATE"))
    }
}

@Test func daemonResponseMetadataRetainsCodesWithoutPrivatePayloads() {
    let error = Data(#"{"id":"ascd-1","error":{"code":403,"message":"PRIVATE-TESTER","data":"PRIVATE-COMMENT"}}"#.utf8)
    let metadata = ASCDaemonClient.responseMetadata(from: error)
    #expect(metadata.id == "ascd-1")
    #expect(metadata.summary == "error code=403")
    let success = Data(#"{"id":"ascd-2","result":{"statusCode":200,"contentType":"application/json","body":"PRIVATE-TESTER"}}"#.utf8)
    let result = ASCDaemonClient.responseMetadata(from: success)
    #expect(result.id == "ascd-2")
    #expect(result.summary.contains("statusCode=200"))
    #expect(result.summary.contains("application/json"))
    #expect(!result.summary.contains("PRIVATE"))
    #expect(ASCDaemonClient.responseMetadata(from: Data("PRIVATE-invalid-json".utf8)).summary == "invalid-json")
}
