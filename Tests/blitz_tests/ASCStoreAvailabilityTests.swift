import Foundation
import Testing
@testable import Blitz

private actor StoreAvailabilityRequests {
    struct Reply {
        let status: Int
        let json: String
        init(_ json: String, status: Int = 200) { self.json = json; self.status = status }
    }
    struct Request {
        let method: String
        let path: String
    }
    private(set) var requests: [Request] = []
    private var replies: [Reply]
    init(_ replies: [Reply]) { self.replies = replies }

    func request(_ method: String, _ path: String, _ headers: [String: String], _ body: Data?) throws -> ASCDaemonClient.HTTPResponse {
        requests.append(.init(method: method, path: path))
        guard method == "GET", body == nil, !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        return .init(statusCode: reply.status, headers: [:], contentType: "application/json", body: Data(reply.json.utf8))
    }

    nonisolated func service() -> AppStoreConnectService {
        AppStoreConnectService(requestTransport: { try await self.request($0, $1, $2, $3) })
    }
}

private func storeAvailabilityResource(id: String = "123", type: String = "appAvailabilities") -> String {
    #"{"data":{"id":"\#(id)","type":"\#(type)"}}"#
}

private func storeTerritory(_ id: String, attributes: String = #"{"available":true,"contentStatuses":["AVAILABLE"]}"#) -> String {
    #"{"id":"\#(id)","type":"territoryAvailabilities","attributes":\#(attributes)}"#
}

private func storeTerritoryPage(_ resources: [String], next: String? = nil) -> String {
    let nextJSON = next.map { #""\#($0)""# } ?? "null"
    return #"{"data":[\#(resources.joined(separator: ","))],"links":{"next":\#(nextJSON)}}"#
}

@Test func storeAvailabilityRequiresPublishedContentAndEnabledTerritory() async throws {
    let cases: [(String, ASCStoreAvailability)] = [
        (#"{"available":true,"contentStatuses":["AVAILABLE"]}"#, .available),
        (#"{"available":false,"contentStatuses":["AVAILABLE"]}"#, .unavailable),
        (#"{"available":false,"contentStatuses":["CANNOT_SELL"]}"#, .unavailable),
        (#"{"available":true,"contentStatuses":["PROCESSING_TO_AVAILABLE"]}"#, .unavailable),
        (#"{"available":true,"contentStatuses":["AVAILABLE_FOR_PREORDER"]}"#, .unavailable),
        (#"{"available":true,"contentStatuses":["AVAILABLE_FOR_SALE_UNRELEASED_APP"]}"#, .unavailable),
        (#"{"available":false,"contentStatuses":[]}"#, .unavailable),
    ]
    for (attributes, expected) in cases {
        let transport = StoreAvailabilityRequests([
            .init(storeAvailabilityResource()), .init(storeTerritoryPage([storeTerritory("territory-a", attributes: attributes)]))
        ])
        #expect(try await transport.service().fetchStoreAvailability(appId: "123") == expected)
    }
}

@Test func storeAvailabilityRegressesReleasedAppWith175DisabledTerritories() async throws {
    // Anonymized reproduction: a released app had 175 territories, all with
    // available=false and CANNOT_SELL. A released version alone is not live.
    let territories = (1...175).map {
        storeTerritory("territory-\($0)", attributes: #"{"available":false,"contentStatuses":["CANNOT_SELL"]}"#)
    }
    let transport = StoreAvailabilityRequests([
        .init(storeAvailabilityResource()), .init(storeTerritoryPage(territories))
    ])
    #expect(try await transport.service().fetchStoreAvailability(appId: "123") == .unavailable)
    #expect(await transport.requests.count == 2)
}

@Test func storeAvailabilityFollowsAllPagesAndPreservesAvailabilityScope() async throws {
    let unavailable = storeTerritory("territory-a", attributes: #"{"available":false,"contentStatuses":["CANNOT_SELL"]}"#)
    let transport = StoreAvailabilityRequests([
        .init(storeAvailabilityResource()),
        .init(storeTerritoryPage([unavailable], next: "?cursor=page2")),
        .init(storeTerritoryPage([unavailable, storeTerritory("territory-b")])),
    ])
    #expect(try await transport.service().fetchStoreAvailability(appId: "123") == .available)
    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(requests[0].path == "/v1/apps/123/appAvailabilityV2")
    for request in requests.dropFirst() {
        let components = try #require(URLComponents(string: request.path))
        #expect(components.path == "/v2/appAvailabilities/123/territoryAvailabilities")
        #expect(components.queryItems?.contains(.init(name: "limit", value: "200")) == true)
    }
    #expect(URLComponents(string: requests[2].path)?.queryItems?.contains(.init(name: "cursor", value: "page2")) == true)
}

@Test func storeAvailabilityDistinguishesKnownEmptyFromIncompleteData() async throws {
    let empty = StoreAvailabilityRequests([.init(storeAvailabilityResource()), .init(storeTerritoryPage([]))])
    #expect(try await empty.service().fetchStoreAvailability(appId: "123") == .unavailable)
    for json in [#"{"data":[]}"#, #"{"links":{"next":null}}"#, #"{"data":null,"links":{"next":null}}"#] {
        let transport = StoreAvailabilityRequests([.init(storeAvailabilityResource()), .init(json)])
        await #expect(throws: (any Error).self) { try await transport.service().fetchStoreAvailability(appId: "123") }
    }
}

@Test func storeAvailabilityUnknownAttributesNeverBecomeUnavailable() async throws {
    let uncertain = [
        #"{}"#, #"null"#, #""invalid""#,
        #"{"available":true}"#,
        #"{"available":true,"contentStatuses":[]}"#,
        #"{"contentStatuses":["AVAILABLE"]}"#,
        #"{"available":false,"contentStatuses":null}"#,
        #"{"available":"false","contentStatuses":["CANNOT_SELL"]}"#,
        #"{"available":false,"contentStatuses":"CANNOT_SELL"}"#,
        #"{"available":false,"contentStatuses":["FUTURE_STATUS"]}"#,
        #"{"available":true,"contentStatuses":["available"]}"#,
    ]
    for attributes in uncertain {
        let transport = StoreAvailabilityRequests([
            .init(storeAvailabilityResource()), .init(storeTerritoryPage([storeTerritory("unknown", attributes: attributes)]))
        ])
        await #expect(throws: (any Error).self) { try await transport.service().fetchStoreAvailability(appId: "123") }
    }
    let positive = StoreAvailabilityRequests([
        .init(storeAvailabilityResource()),
        .init(storeTerritoryPage([storeTerritory("unknown", attributes: #"{}"#)], next: "?cursor=next")),
        .init(storeTerritoryPage([storeTerritory("known")]))
    ])
    #expect(try await positive.service().fetchStoreAvailability(appId: "123") == .available)
}

@Test func storeAvailabilityDoesNotSwallow404OrLaterPageFailure() async throws {
    for failureAt in [0, 1, 2] {
        var replies: [StoreAvailabilityRequests.Reply] = [.init(storeAvailabilityResource())]
        if failureAt == 2 { replies.append(.init(storeTerritoryPage([storeTerritory("known")], next: "?cursor=next"))) }
        if failureAt == 0 { replies.removeAll() }
        replies.append(.init(#"{"errors":[{"status":"404","detail":"Not found"}]}"#, status: 404))
        let transport = StoreAvailabilityRequests(replies)
        do {
            _ = try await transport.service().fetchStoreAvailability(appId: "123")
            Issue.record("A failed availability read must remain unknown")
        } catch let ASCError.httpError(code, _) {
            #expect(code == 404)
        }
        #expect(await transport.requests.count == failureAt + 1)
    }
}

@Test func storeAvailabilityRejectsUnsafeResourceIDsAndTypes() async throws {
    for id in ["", "../other", "123?other=1", "123/other"] {
        let transport = StoreAvailabilityRequests([])
        await #expect(throws: (any Error).self) { try await transport.service().fetchStoreAvailability(appId: id) }
        #expect(await transport.requests.isEmpty)
        let availability = StoreAvailabilityRequests([.init(storeAvailabilityResource(id: id))])
        await #expect(throws: (any Error).self) { try await availability.service().fetchStoreAvailability(appId: "123") }
        #expect(await availability.requests.count == 1)
    }
    let wrongType = StoreAvailabilityRequests([.init(storeAvailabilityResource(type: "apps"))])
    await #expect(throws: (any Error).self) { try await wrongType.service().fetchStoreAvailability(appId: "123") }
    #expect(await wrongType.requests.count == 1)
}

@Test func storeAvailabilityRejectsScopeChangesCyclesAndContradictoryDuplicates() async throws {
    let endpoint = "/v2/appAvailabilities/123/territoryAvailabilities"
    for next in [
        "https://example.org\(endpoint)?cursor=x",
        "/v2/appAvailabilities/other/territoryAvailabilities?cursor=x",
        "\(endpoint)?limit=200",
        "\(endpoint)?cursor=x&filter[available]=false",
        "\(endpoint)?cursor=x&cursor=y",
        "\(endpoint)?limit=0",
    ] {
        let transport = StoreAvailabilityRequests([
            .init(storeAvailabilityResource()), .init(storeTerritoryPage([], next: next))
        ])
        await #expect(throws: (any Error).self) { try await transport.service().fetchStoreAvailability(appId: "123") }
        #expect(await transport.requests.count == 2)
    }
    let conflict = StoreAvailabilityRequests([
        .init(storeAvailabilityResource()),
        .init(storeTerritoryPage([storeTerritory("same")], next: "?cursor=next")),
        .init(storeTerritoryPage([storeTerritory("same", attributes: #"{"available":false,"contentStatuses":["CANNOT_SELL"]}"#)])),
    ])
    await #expect(throws: (any Error).self) { try await conflict.service().fetchStoreAvailability(appId: "123") }
    #expect(await conflict.requests.count == 3)
}
