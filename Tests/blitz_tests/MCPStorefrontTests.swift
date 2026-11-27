import Foundation
import Testing
@testable import Blitz

@Suite struct MCPStorefrontTests {
    private let appID = "app1"
    private func selection(_ options: [String: Any] = ["allCurrentTerritories": true]) throws -> StorefrontSelection {
        try StorefrontSelection(arguments: ["confirm": true, "available": true].merging(options) { _, value in value })
    }

    @Test func requiresExplicitScopeAndRealBooleans() throws {
        for invalid: [String: Any] in [
            [:], ["territoryCodes": []], ["territoryCodes": ["deu"]], ["territoryCodes": ["DEU", "DEU"]],
            ["allCurrentTerritories": false], ["allCurrentTerritories": true, "territoryCodes": ["DEU"]],
            ["allCurrentTerritories": 1], ["allCurrentTerritories": true, "available": "false"],
            ["allCurrentTerritories": true, "confirm": false], ["allCurrentTerritories": true, "initialAvailableInNewTerritories": 1]
        ] {
            #expect(throws: (any Error).self) { try selection(invalid) }
        }
    }

    @Test func comparesAllCatalogAndAvailabilityPages() async throws {
        let fixture = StorefrontFixture()
        let snapshot = try await fixture.service().storefronts(appID: appID, validate: {})
        #expect(snapshot.payload["availableTerritories"] as? [String] == ["USA"])
        #expect(snapshot.payload["unavailableTerritories"] as? [String] == ["DEU", "FRA"])
        #expect(snapshot.payload["allCurrentTerritoriesAvailable"] as? Bool == false)
        #expect(snapshot.availableInNewTerritories == false)
        #expect(await fixture.pageTwoReads == 2)
    }

    @Test func flagsOnlySelectedCountriesAndVerifiesActualReturnedFlags() async throws {
        let fixture = StorefrontFixture()
        let service = fixture.service()
        let selected = try selection(["territoryCodes": ["DEU"]])
        let receipt = try await service.updateStorefronts(appID: appID, selection: selected, validate: {})
        #expect(receipt["verified"] as? Bool == true)
        let payload = try #require(receipt["availability"] as? [String: Any])
        #expect(payload["availableTerritories"] as? [String] == ["DEU", "USA"])
        #expect(payload["availableInNewTerritories"] as? Bool == false)
        #expect(await fixture.written == ["DEU"])
        let repeated = try await service.updateStorefronts(appID: appID, selection: selected, validate: {})
        #expect(repeated["outcome"] as? String == "alreadyConfigured")
        #expect(await fixture.written == ["DEU"])

        let all = try await service.updateStorefronts(appID: appID, selection: selection(), validate: {})
        let worldwide = try #require(all["availability"] as? [String: Any])
        #expect(worldwide["allCurrentTerritoriesAvailable"] as? Bool == true)
        #expect(worldwide["availableInNewTerritories"] as? Bool == false)
        #expect(await fixture.written == ["DEU", "FRA"])
    }

    @Test func disablingSelectedCountryPreservesOtherCountriesAndFuturePolicy() async throws {
        let fixture = StorefrontFixture()
        let service = fixture.service()
        let wrongPolicy = try selection(["territoryCodes": ["USA"], "available": false, "initialAvailableInNewTerritories": true])
        await #expect(throws: (any Error).self) { try await service.updateStorefronts(appID: appID, selection: wrongPolicy, validate: {}) }
        #expect(await fixture.written.isEmpty)
        let remove = try selection(["territoryCodes": ["USA"], "available": false])
        let result = try await service.updateStorefronts(appID: appID, selection: remove, validate: {})
        let state = try #require(result["availability"] as? [String: Any])
        #expect(result["verified"] as? Bool == true)
        #expect(state["availableTerritories"] as? [String] == [])
        #expect(state["availableInNewTerritories"] as? Bool == false)
        #expect(await fixture.written == ["USA"])
    }

    @Test func missingRowsAndAttributesAreUnknown() async throws {
        let fixture = StorefrontFixture()
        await fixture.configure(.incomplete)
        let service = fixture.service()
        let state = try await service.storefronts(appID: appID, validate: {})
        #expect(state.payload["unknownTerritories"] as? [String] == ["DEU", "FRA"])
        #expect(state.payload["allCurrentTerritoriesAvailable"] is NSNull)
        await #expect(throws: (any Error).self) { try await service.updateStorefronts(appID: appID, selection: selection(), validate: {}) }
        #expect(await fixture.written.isEmpty)
    }

    @Test(arguments: [StorefrontFixture.Mode.otherOrigin, .scopeChange, .truncated, .duplicate])
    private func refusesUnreliableCatalogs(_ mode: StorefrontFixture.Mode) async throws {
        let fixture = StorefrontFixture()
        await fixture.configure(mode)
        await #expect(throws: (any Error).self) { try await fixture.service().updateStorefronts(appID: appID, selection: selection(), validate: {}) }
        #expect(await fixture.written.isEmpty)
    }

    @Test func lostReplyIsReadBackAndDoesNotReplayRemainingWrites() async throws {
        let fixture = StorefrontFixture()
        await fixture.configure(.lostReply)
        let result = try await fixture.service().updateStorefronts(appID: appID, selection: selection(), validate: {})
        #expect(result["verified"] as? Bool == false)
        #expect(result["unconfirmedTerritories"] as? [String] == ["FRA"])
        #expect(result["attemptedTerritories"] as? [String] == ["DEU"])
        #expect(await fixture.written == ["DEU"])
    }

    @Test func acknowledgedButUnappliedChangeFailsReadback() async throws {
        let fixture = StorefrontFixture()
        await fixture.configure(.unapplied)
        let result = try await fixture.service().updateStorefronts(appID: appID, selection: selection(["territoryCodes": ["FRA"]]), validate: {})
        #expect(result["verified"] as? Bool == false)
        #expect(result["unconfirmedTerritories"] as? [String] == ["FRA"])
    }

    @Test func firstSetupRequiresPolicyAndSetsOtherCountriesUnavailable() async throws {
        let fixture = StorefrontFixture()
        await fixture.configure(.notConfigured)
        let service = fixture.service()
        await #expect(throws: (any Error).self) { try await service.updateStorefronts(appID: appID, selection: selection(), validate: {}) }
        #expect(await fixture.posts == 0)
        let selected = try selection(["territoryCodes": ["DEU"], "initialAvailableInNewTerritories": true])
        let result = try await service.updateStorefronts(appID: appID, selection: selected, validate: {})
        let snapshot = try #require(result["availability"] as? [String: Any])
        #expect(result["verified"] as? Bool == true)
        #expect(snapshot["availableTerritories"] as? [String] == ["DEU"])
        #expect(snapshot["unavailableTerritories"] as? [String] == ["FRA", "USA"])
        #expect(snapshot["availableInNewTerritories"] as? Bool == true)
        #expect(await fixture.posts == 1)
    }

    @Test func generic404DoesNotAuthorizeCreatingAvailability() async throws {
        let fixture = StorefrontFixture()
        await fixture.configure(.generic404)
        let selected = try selection(["allCurrentTerritories": true, "initialAvailableInNewTerritories": false])
        await #expect(throws: (any Error).self) { try await fixture.service().updateStorefronts(appID: appID, selection: selected, validate: {}) }
        #expect(await fixture.posts == 0)
    }
}

private actor StorefrontFixture {
    enum Mode { case normal, incomplete, otherOrigin, scopeChange, duplicate, truncated, lostReply, unapplied, notConfigured, generic404 }
    private var mode = Mode.normal
    private var flags = ["DEU": false, "FRA": false, "USA": true]
    private var future = false
    private(set) var written: [String] = []
    private(set) var posts = 0
    private(set) var pageTwoReads = 0
    func configure(_ mode: Mode) { self.mode = mode }
    nonisolated func service() -> AppStoreConnectService {
        AppStoreConnectService(requestTransport: { try await self.request($0, $1, $3) })
    }

    private func request(_ method: String, _ path: String, _ body: Data?) throws -> ASCDaemonClient.HTTPResponse {
        let url = try #require(URLComponents(string: path))
        let pageTwo = url.queryItems?.contains(.init(name: "cursor", value: "next")) == true
        if pageTwo { pageTwoReads += 1 }
        let catalog = url.path == "/v1/territories"
        var json: [String: Any] = [:]
        var status = 200
        if method == "GET", catalog || url.path == "/v2/appAvailabilities/conf/territoryAvailabilities" {
            var codes = pageTwo ? ["USA", "FRA"] : ["DEU"]
            if catalog, pageTwo, mode == .duplicate { codes.append("DEU") }
            if !catalog, mode == .incomplete { codes.removeAll { $0 == "FRA" } }
            let data: [[String: Any]] = codes.map { code in
                if catalog { return ["type": "territories", "id": code] }
                let attributes = mode == .incomplete && code == "DEU" ? [:] : ["available": flags[code]!]
                return ["type": "territoryAvailabilities", "id": "row-\(code)",
                        "relationships": ["territory": ["data": ["type": "territories", "id": code]]], "attributes": attributes]
            }
            var next: String? = pageTwo ? nil : "?cursor=next"
            if catalog, !pageTwo {
                if mode == .otherOrigin { next = "https://example.org/v1/territories?cursor=next" }
                if mode == .scopeChange { next = "?cursor=next&filter%5Bid%5D=USA" }
                if mode == .truncated { next = nil }
            }
            json = ["data": data, "links": ["next": next.map { $0 as Any } ?? NSNull()],
                    "meta": ["paging": ["total": !catalog && mode == .incomplete ? 2 : 3]]]
        } else if method == "GET", url.path == "/v1/apps/app1/appAvailabilityV2" {
            if mode == .notConfigured || mode == .generic404 {
                status = 404
                json = ["errors": [["detail": mode == .generic404 ? "App not found." : "No appAvailabilities resource exists."]]]
            } else {
                json = ["data": ["type": "appAvailabilities", "id": "conf", "attributes": ["availableInNewTerritories": future]] as [String: Any]]
            }
        } else if method == "PATCH", url.path.hasPrefix("/v1/territoryAvailabilities/row-") {
            let code = String(url.path.suffix(3))
            let bytes = try #require(body)
            let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let data = try #require(object["data"] as? [String: Any])
            let attrs = try #require(data["attributes"] as? [String: Bool])
            #expect(data["id"] as? String == "row-\(code)")
            #expect(data["type"] as? String == "territoryAvailabilities")
            #expect(Set(attrs.keys) == ["available"])
            written.append(code)
            if mode != .unapplied { flags[code] = attrs["available"] }
            if mode == .lostReply { throw URLError(.networkConnectionLost) }
        } else if method == "POST", url.path == "/v2/appAvailabilities", mode == .notConfigured {
            let bytes = try #require(body)
            let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let data = try #require(object["data"] as? [String: Any])
            let futureValue: Bool? = (data["attributes"] as? [String: Bool])?["availableInNewTerritories"]
            future = try #require(futureValue as Bool?)
            let included = try #require(object["included"] as? [[String: Any]])
            #expect(included.count == flags.count)
            for row in included {
                let relation = try #require((row["relationships"] as? [String: [String: [String: String]]])?["territory"]?["data"]?["id"])
                flags[relation] = try #require((row["attributes"] as? [String: Bool])?["available"])
            }
            posts += 1
            mode = .normal
        } else { throw URLError(.unsupportedURL) }
        return .init(statusCode: status, headers: [:], contentType: "application/json", body: try JSONSerialization.data(withJSONObject: json))
    }
}
