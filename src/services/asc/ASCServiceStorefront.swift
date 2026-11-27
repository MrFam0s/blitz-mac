import Foundation

struct StorefrontSnapshot {
    let appID: String
    let availabilityID: String?
    let availableInNewTerritories: Bool?
    let catalog: Set<String>
    let territories: [String: StorefrontRow]

    var payload: [String: Any] {
        let enabled = catalog.filter { territories[$0]?.available == true }.sorted()
        let disabled = catalog.filter { territories[$0]?.available == false }.sorted()
        let unknown = catalog.subtracting(enabled).subtracting(disabled).sorted()
        let worldwide: Bool? = !disabled.isEmpty ? false : (unknown.isEmpty ? true : nil)
        return ["appId": appID, "configured": availabilityID != nil,
                "availableInNewTerritories": availableInNewTerritories.map { $0 as Any } ?? NSNull(),
                "currentTerritoryCount": catalog.count,
                "allCurrentTerritoriesAvailable": worldwide.map { $0 as Any } ?? NSNull(),
                "availableTerritories": enabled, "unavailableTerritories": disabled, "unknownTerritories": unknown]
    }
}

struct StorefrontRow {
    let id: String
    let available: Bool?
}

private struct StorefrontResource: Decodable {
    let type: String
    let id: String
    let attributes: Attributes?
    let relationships: Relationships?
    struct Attributes: Decodable {
        let available: Bool?
        let availableInNewTerritories: Bool?
    }
    struct Relationships: Decodable {
        let territory: Linkage?
        struct Linkage: Decodable {
            let data: Territory?
            struct Territory: Decodable {
                let type: String
                let id: String
            }
        }
    }
}

private struct StorefrontPage: Decodable {
    let data: [StorefrontResource]
    let links: Links
    let meta: Meta?
    struct Links: Decodable { let next: String? }
    struct Meta: Decodable {
        let paging: Paging?
        struct Paging: Decodable { let total: Int? }
    }
}

extension AppStoreConnectService {
    func storefronts(appID: String, validate: () async throws -> Void) async throws -> StorefrontSnapshot {
        guard ReleaseWorkflowTarget.validID(appID) else { throw ASCError.invalidURL }
        let resources = try await storefrontPages("/v1/territories", query: [], validate: validate)
        guard !resources.isEmpty, resources.allSatisfy({ $0.type == "territories" && StorefrontSelection.validCode($0.id) }) else {
            throw ASCError.notFound("Apple returned an incomplete territory catalog.")
        }
        let catalog = Set(resources.map(\.id))
        try await validate()
        let configuration: StorefrontResource?
        do {
            let response = try await get("/v1/apps/\(appID)/appAvailabilityV2", as: ASCSingleResponse<StorefrontResource?>.self)
            configuration = response.data
        } catch let ASCError.httpError(404, body) where Self.missingStorefrontConfiguration(body) {
            configuration = nil
        }
        guard let configuration else {
            return StorefrontSnapshot(appID: appID, availabilityID: nil, availableInNewTerritories: nil, catalog: catalog, territories: [:])
        }
        guard configuration.type == "appAvailabilities", Self.safeStorefrontID(configuration.id) else { throw ASCError.invalidURL }
        let query = [URLQueryItem(name: "include", value: "territory"),
                     URLQueryItem(name: "fields[territoryAvailabilities]", value: "available,territory")]
        let endpoint = "/v2/appAvailabilities/\(configuration.id)/territoryAvailabilities"
        let rows = try await storefrontPages(endpoint, query: query, validate: validate)
        var territories: [String: StorefrontRow] = [:]
        for row in rows {
            guard row.type == "territoryAvailabilities", Self.safeStorefrontID(row.id),
                  let territory = row.relationships?.territory?.data, territory.type == "territories",
                  catalog.contains(territory.id), territories[territory.id] == nil else {
                throw ASCError.notFound("Apple returned ambiguous territory availability data.")
            }
            territories[territory.id] = StorefrontRow(id: row.id, available: row.attributes?.available)
        }
        return StorefrontSnapshot(appID: appID, availabilityID: configuration.id,
                                  availableInNewTerritories: configuration.attributes?.availableInNewTerritories,
                                  catalog: catalog, territories: territories)
    }

    private func storefrontPages(_ endpoint: String, query: [URLQueryItem], validate: () async throws -> Void) async throws -> [StorefrontResource] {
        let initial = query + [URLQueryItem(name: "limit", value: "200")]
        let allowed = Set(initial.map(\.name)).union(["cursor"])
        var next: String? = endpoint
        var pages = Set<String>(), ids = Set<String>()
        var result: [StorefrontResource] = []
        var expectedTotal: Int?
        while let page = next {
            try Task.checkCancellation()
            try await validate()
            let url = try paginationPath(page, queryItems: initial, endpoint: endpoint)
            let items = URLComponents(string: url)?.queryItems ?? []
            guard pages.count < 500, pages.insert(url).inserted,
                  items.allSatisfy({ allowed.contains($0.name) }), Set(items.map(\.name)).count == items.count,
                  query.allSatisfy(items.contains),
                  let limitValue = items.first(where: { $0.name == "limit" })?.value,
                  let limit = Int(limitValue), (1...200).contains(limit) else { throw ASCError.invalidURL }
            let response = try await get(url, as: StorefrontPage.self)
            if let total = response.meta?.paging?.total {
                guard total >= 0, expectedTotal == nil || expectedTotal == total else { throw ASCError.invalidURL }
                expectedTotal = total
            }
            for row in response.data {
                guard ids.insert(row.id).inserted else { throw ASCError.notFound("Apple returned duplicate territory data.") }
                result.append(row)
            }
            next = response.links.next.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard expectedTotal == nil || result.count == expectedTotal else { throw ASCError.notFound("Apple returned an incomplete territory list.") }
        return result
    }

    private static func safeStorefrontID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 1024 && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43, 45, 61, 95].contains($0)
        }
    }

    // Mirrors ASC's typed missing-resource check. A generic 404 may also mean the app is inaccessible.
    private static func missingStorefrontConfiguration(_ body: String) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]], !errors.isEmpty else { return false }
        return errors.allSatisfy {
            let detail = ($0["detail"] as? String ?? "").lowercased()
            return detail.contains("no resource of type 'appavailabilities'") || detail.contains("no appavailabilities resource")
        }
    }
}

extension AppStoreConnectService {
    func updateStorefronts(appID: String, selection: StorefrontSelection, validate: () async throws -> Void) async throws -> [String: Any] {
        let before = try await storefronts(appID: appID, validate: validate)
        let target = selection.territoryCodes ?? before.catalog
        guard target.isSubset(of: before.catalog) else { throw ASCError.notFound("The selection includes an unknown Apple territory code.") }

        let isInitial = before.availabilityID == nil
        let changed: [String]
        if isInitial {
            guard selection.available, selection.initialFutureAvailability != nil else {
                throw ASCError.notFound("First setup requires an enabled selection and an explicit initialAvailableInNewTerritories setting.")
            }
            changed = target.sorted()
        } else {
            guard selection.initialFutureAvailability == nil || selection.initialFutureAvailability == before.availableInNewTerritories else {
                throw ASCError.notFound("The existing future-territory setting differs from the requested initial value.")
            }
            guard target.allSatisfy({ before.territories[$0]?.available != nil }) else {
                throw ASCError.notFound("Apple did not confirm the current flag for every selected territory. Refresh availability before changing it.")
            }
            changed = target.filter { before.territories[$0]?.available != selection.available }.sorted()
        }
        guard !changed.isEmpty else {
            return ["verified": true, "outcome": "alreadyConfigured", "availability": before.payload, "attemptedTerritories": []]
        }

        var attempted: [String] = []
        var writeError: String?
        do {
            if let initialFuture = selection.initialFutureAvailability, isInitial {
                try await validate()
                attempted = before.catalog.sorted()
                try await createAppAvailability(appId: appID, territoryIds: attempted, selectedTerritories: target,
                                                availableInNewTerritories: initialFuture)
            } else {
                for country in changed {
                    try Task.checkCancellation()
                    try await validate()
                    guard let row = before.territories[country] else { throw ASCError.invalidURL }
                    attempted.append(country)
                    let data: [String: Any] = ["type": "territoryAvailabilities", "id": row.id, "attributes": ["available": selection.available]]
                    try await patch(path: "/v1/territoryAvailabilities/\(row.id)", body: ["data": data])
                }
            }
        } catch {
            writeError = Self.storefrontDiagnostic(error)
        }

        var receipt: [String: Any] = ["appId": appID, "verified": false, "outcome": "unverified", "attemptedTerritories": attempted]
        receipt["writeError"] = writeError
        // A dropped connection can follow an accepted PATCH or POST. Read once before reporting the outcome, even after failure.
        let after: StorefrontSnapshot
        do { after = try await storefronts(appID: appID, validate: validate) }
        catch {
            receipt["readbackError"] = Self.storefrontDiagnostic(error)
            return receipt
        }

        let expectedFuture = isInitial ? selection.initialFutureAvailability : before.availableInNewTerritories
        let catalogMatches = before.catalog == after.catalog
        let verifiedTarget = selection.territoryCodes ?? target.union(after.catalog)
        var mismatches = verifiedTarget.filter { after.territories[$0]?.available != selection.available }
        if isInitial {
            mismatches.formUnion(after.catalog.subtracting(target).filter { after.territories[$0]?.available != false })
        }
        let otherChanges = isInitial ? [] : before.catalog.intersection(after.catalog).subtracting(target).filter {
            before.territories[$0]?.available != after.territories[$0]?.available
        }.sorted()
        let sameConfiguration = after.availabilityID != nil && (isInitial || before.availabilityID == after.availabilityID)
        let verified = mismatches.isEmpty && otherChanges.isEmpty && sameConfiguration && (catalogMatches || (!isInitial && selection.territoryCodes != nil))
            && expectedFuture == after.availableInNewTerritories
        receipt["verified"] = verified
        receipt["outcome"] = verified ? "confirmed" : "unverified"
        receipt["availability"] = after.payload
        receipt["unconfirmedTerritories"] = mismatches.sorted()
        receipt["otherChangedTerritories"] = otherChanges
        return receipt
    }

    private static func storefrontDiagnostic(_ error: Error) -> String {
        if case let ASCError.httpError(status, body) = error {
            let response = ReleaseAppleError.sanitized(status: status, body: Data(body.utf8))
            return (["HTTP \(status)"] + response.codes).joined(separator: " ")
        }
        if error is CancellationError { return "Cancelled" }
        // Avoid exposing server response bodies or account data through the tool.
        return "Request or target verification failed."
    }
}
