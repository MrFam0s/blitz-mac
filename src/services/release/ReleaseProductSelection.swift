import Foundation

/// Reads the public, version-based commerce API. Selection is explicit: a catalog
/// lookup proves ownership and dependencies, never adds products to a release.
enum ReleaseProductSelection {
    typealias Single = (String) async throws -> [String: Any]?
    typealias All = (String, [String: String]) async throws -> [[String: Any]]

    struct Result {
        let protectedContent: [[String: Any]]
        let diagnostics: [ReleaseReadinessDiagnostic]
        /// Whole-app evidence for the two precise attachment checks, not a waiver
        /// for arbitrary product, agreement, pricing or metadata findings.
        let attachmentEvidence: [String: String]

        func replacesAttachmentFinding(_ id: String) -> Bool {
            if attachmentEvidence["iap.first_type_app_version_attachment"] != nil,
               id == "iap.first_type_app_version_attachment" { return true }
            return attachmentEvidence["subscriptions.first_type_app_version_attachment"] != nil &&
                ["subscriptions.first_type_app_version_attachment.missing",
                 "deep.subscriptions.first_type_app_version_attachment.unverified"].contains(id)
        }
    }

    static func inspect(target: ReleaseWorkflowTarget, single: @escaping Single,
                        all: @escaping All) async throws -> Result {
        try target.validate()
        guard !target.reviewItems.isEmpty else { return .init(protectedContent: [], diagnostics: [], attachmentEvidence: [:]) }
        return try await Reader(target: target, single: single, all: all).inspect()
    }

    private final class Reader {
        let target: ReleaseWorkflowTarget
        let single: Single
        let all: All
        var cachedLists: [String: [[String: Any]]] = [:]
        var diagnostics: [ReleaseReadinessDiagnostic] = []
        var selectedParents: Set<String> = []
        var selectedIAPTypes: Set<String> = []
        var selectedSubscriptionGroups: Set<String> = []
        var selectedGroupIDs: Set<String> = []
        var groupHistory: [String: [[String: Any]]] = [:]

        init(target: ReleaseWorkflowTarget, single: @escaping Single, all: @escaping All) {
            self.target = target; self.single = single; self.all = all
        }

        func inspect() async throws -> Result {
            let iaps = try await list("/v1/apps/\(target.appID)/inAppPurchasesV2", type: "inAppPurchases")
            let groups = try await list("/v1/apps/\(target.appID)/subscriptionGroups", type: "subscriptionGroups")
            var subscriptions: [String: [String: Any]] = [:]
            var subscriptionGroups: [String: String] = [:]
            for group in groups {
                let id = try Self.id(group)
                try Self.checkOptionalOwner(group, relationship: "app", type: "apps", id: target.appID)
                for subscription in try await list("/v1/subscriptionGroups/\(id)/subscriptions", type: "subscriptions") {
                    let subscriptionID = try Self.id(subscription)
                    guard subscriptions[subscriptionID] == nil else { throw ReleaseWorkflowAPIError.invalidResponse }
                    try Self.checkOptionalOwner(subscription, relationship: "group", type: "subscriptionGroups", id: id)
                    subscriptions[subscriptionID] = subscription
                    subscriptionGroups[subscriptionID] = id
                }
            }
            for iap in iaps { try Self.checkOptionalOwner(iap, relationship: "app", type: "apps", id: target.appID) }
            let iapsByID = try Self.index(iaps)
            let groupsByID = try Self.index(groups)
            var protected: [[String: Any]] = []
            for item in target.reviewItems.sorted(by: { $0.key < $1.key }) {
                let parentType: String, parentName: String, parentPrefix: String
                switch item.type {
                case .inAppPurchaseVersions:
                    parentType = "inAppPurchases"; parentName = "inAppPurchase"; parentPrefix = "/v2/inAppPurchases"
                case .subscriptionVersions:
                    parentType = "subscriptions"; parentName = "subscription"; parentPrefix = "/v1/subscriptions"
                case .subscriptionGroupVersions:
                    parentType = "subscriptionGroups"; parentName = "subscriptionGroup"; parentPrefix = "/v1/subscriptionGroups"
                }
                guard let version = try await single("/v1/\(item.type.rawValue)/\(item.id)?include=\(parentName)"),
                      version["type"] as? String == item.type.rawValue, version["id"] as? String == item.id else {
                    throw ReleaseWorkflowError.identityChanged
                }
                let parentID = try Self.owner(version, relationship: parentName, type: parentType)
                let catalog = item.type == .inAppPurchaseVersions ? iapsByID : (item.type == .subscriptionVersions ? subscriptions : groupsByID)
                guard let parent = catalog[parentID] else { throw ReleaseWorkflowError.identityChanged }
                guard selectedParents.insert("\(parentType):\(parentID)").inserted else { throw ReleaseWorkflowError.invalidTarget }
                let history = try await list("\(parentPrefix)/\(parentID)/versions", type: item.type.rawValue)
                guard let listed = history.first(where: { $0["id"] as? String == item.id }),
                      Self.attributes(listed)["version"] as? Int == Self.attributes(version)["version"] as? Int else {
                    throw ReleaseWorkflowError.identityChanged
                }
                if Self.text(Self.attributes(listed)["state"]) != Self.text(Self.attributes(version)["state"]) {
                    issue(item.key, "version_state_changed_during_read")
                }
                inspectVersion(version, history: history, key: item.key)
                let localizations = try await list("/v1/\(item.type.rawValue)/\(item.id)/localizations",
                    type: item.type == .inAppPurchaseVersions ? "inAppPurchaseLocalizations" :
                        (item.type == .subscriptionVersions ? "subscriptionLocalizations" : "subscriptionGroupLocalizations"))
                inspectLocalizations(localizations, item: item)
                var value: [String: Any] = ["selection": ["type": item.type.rawValue, "id": item.id],
                    "parent": Self.semantic(parent), "version": Self.semantic(version),
                    "owner": ["type": parentType, "id": parentID],
                    "localizations": localizations.map { Self.semantic($0) }]
                if item.type == .subscriptionGroupVersions {
                    selectedGroupIDs.insert(parentID)
                    groupHistory[parentID] = history
                    if Self.text(Self.attributes(parent)["referenceName"]).isEmpty { issue(item.key, "group_name_missing", status: "blocked") }
                } else {
                    let attributes = Self.attributes(parent)
                    if Self.text(attributes["productId"]).isEmpty || Self.text(attributes["name"]).isEmpty {
                        issue(item.key, "product_identity_incomplete", status: "blocked")
                    }
                    let state = Self.text(attributes["state"])
                    if !Self.catalogStates.contains(state) { issue(item.key, "product_state_unverified") }
                    if ["MISSING_METADATA", "WAITING_FOR_UPLOAD", "PROCESSING_CONTENT", "DEVELOPER_ACTION_NEEDED"].contains(state) {
                        issue(item.key, "product_metadata_incomplete", status: "blocked")
                    }
                    if item.type == .inAppPurchaseVersions {
                        let kind = Self.text(attributes["inAppPurchaseType"])
                        guard Self.iapTypes.contains(kind) else { throw ReleaseWorkflowAPIError.invalidResponse }
                        selectedIAPTypes.insert(kind)
                    } else {
                        guard let groupID = subscriptionGroups[parentID] else { throw ReleaseWorkflowError.identityChanged }
                        selectedSubscriptionGroups.insert(groupID)
                        value["subscriptionGroupId"] = groupID
                        groupHistory[groupID] = try await list("/v1/subscriptionGroups/\(groupID)/versions", type: "subscriptionGroupVersions")
                        if Self.text(attributes["subscriptionPeriod"]).isEmpty { issue(item.key, "subscription_period_missing", status: "blocked") }
                    }
                    let screenshot = try await single("\(parentPrefix)/\(parentID)/appStoreReviewScreenshot")
                    if let screenshot {
                        try Self.checkResource(screenshot, type: item.type == .inAppPurchaseVersions ? "inAppPurchaseAppStoreReviewScreenshots" : "subscriptionAppStoreReviewScreenshots")
                        inspectAsset(screenshot, key: item.key, role: "review_screenshot")
                        value["reviewScreenshot"] = Self.assetSemantic(screenshot)
                    } else { issue(item.key, "review_screenshot_missing", status: "blocked") }
                    let images = try await list("/v1/\(item.type.rawValue)/\(item.id)/images",
                        type: item.type == .inAppPurchaseVersions ? "inAppPurchaseImages" : "subscriptionImages")
                    for image in images { inspectAsset(image, key: item.key, role: "promotion_image") }
                    value["images"] = images.map(Self.assetSemantic)
                    if let primaryImage = try await single("/v1/\(item.type.rawValue)/\(item.id)/image") {
                        try Self.checkResource(primaryImage, type: item.type == .inAppPurchaseVersions ? "inAppPurchaseImages" : "subscriptionImages")
                        inspectAsset(primaryImage, key: item.key, role: "primary_promotion_image")
                        value["primaryImage"] = Self.assetSemantic(primaryImage)
                    }
                    value["commerce"] = try await commerce(parentID: parentID, isIAP: item.type == .inAppPurchaseVersions, key: item.key)
                }
                protected.append(value)
            }
            for (groupID, history) in groupHistory where !Self.knownHistory(history) {
                issue("subscriptionGroups:\(groupID)", "group_history_unverified")
            }
            for groupID in selectedSubscriptionGroups where !Self.approved(groupHistory[groupID] ?? []) && !selectedGroupIDs.contains(groupID) {
                issue("subscriptionGroups:\(groupID)", "unapproved_group_version_not_selected", status: "blocked")
            }
            for groupID in selectedGroupIDs where !Self.approved(groupHistory[groupID] ?? []) && !selectedSubscriptionGroups.contains(groupID) {
                issue("subscriptionGroups:\(groupID)", "new_group_requires_selected_subscription", status: "blocked")
            }
            var evidence: [String: String] = [:]
            // Upstream attachment checks are app-wide. Replace them only after
            // inspecting every catalog identity/type/state, including unselected
            // products, and proving coverage for every ready first-of-type group.
            if diagnostics.isEmpty {
                if try await iapAttachmentSatisfied(iaps) {
                    evidence["iap.first_type_app_version_attachment"] = "complete_catalog_and_explicit_version_selection_verified"
                } else { issue("catalog", "iap_attachment_coverage_unverified") }
                if try await subscriptionAttachmentSatisfied(Array(subscriptions.values)) {
                    evidence["subscriptions.first_type_app_version_attachment"] = "complete_catalog_and_explicit_version_selection_verified"
                } else { issue("catalog", "subscription_attachment_coverage_unverified") }
            }
            return .init(protectedContent: protected, diagnostics: diagnostics, attachmentEvidence: evidence)
        }

        private func list(_ path: String, type: String, query: [String: String] = [:]) async throws -> [[String: Any]] {
            let cacheKey = path + query.keys.sorted().map { "|\($0)=\(query[$0]!)" }.joined()
            if let cached = cachedLists[cacheKey] { return cached }
            let values = try await all(path, query)
            var ids: Set<String> = []
            for value in values {
                try Self.checkResource(value, type: type)
                guard ids.insert(try Self.id(value)).inserted else { throw ReleaseWorkflowAPIError.invalidResponse }
            }
            let ordered = values.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
            cachedLists[cacheKey] = ordered
            return ordered
        }

        private func inspectVersion(_ version: [String: Any], history: [[String: Any]], key: String) {
            let attrs = Self.attributes(version)
            guard let number = attrs["version"] as? Int, number > 0,
                  Self.knownHistory(history), Self.versionStates.contains(Self.text(attrs["state"])) else {
                issue(key, "version_history_unverified"); return
            }
            if !["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW"].contains(Self.text(attrs["state"])) {
                issue(key, "version_not_editable", status: "blocked")
            }
            if history.contains(where: { (Self.attributes($0)["version"] as? Int ?? 0) > number ||
                ((Self.attributes($0)["version"] as? Int) == number && $0["id"] as? String != version["id"] as? String) }) {
                issue(key, "version_superseded_or_ambiguous", status: "blocked")
            }
        }

        private func inspectLocalizations(_ values: [[String: Any]], item: ReleaseReviewItem) {
            if values.isEmpty { issue(item.key, "localizations_missing", status: "blocked") }
            var locales: Set<String> = []
            for value in values {
                let attributes = Self.attributes(value)
                let locale = Self.text(attributes["locale"]), name = Self.text(attributes["name"])
                let description = Self.text(attributes["description"])
                if locale.isEmpty || !locales.insert(locale).inserted || name.isEmpty || (item.type != .subscriptionGroupVersions && name.count > 30) ||
                    (item.type != .subscriptionGroupVersions && (description.isEmpty || description.count > 45)) {
                    issue(item.key, "localization_incomplete", status: "blocked", locale: locale.isEmpty ? nil : locale)
                }
            }
        }

        private func inspectAsset(_ asset: [String: Any], key: String, role: String) {
            let attrs = Self.attributes(asset)
            let state = (attrs["assetDeliveryState"] as? [String: Any])?["state"] as? String
            if state != "COMPLETE" { issue(key, "\(role)_not_complete", status: state == "FAILED" ? "blocked" : "unverified") }
            // Version-scoped promotional images expose an assetToken rather than
            // sourceFileChecksum. Either stable identity is sufficient for a
            // fully delivered asset; expiring image URLs alone are not.
            if (Self.text(attrs["sourceFileChecksum"]).isEmpty && Self.text(attrs["assetToken"]).isEmpty) || (attrs["fileSize"] as? Int ?? 0) <= 0 {
                issue(key, "\(role)_content_unverified")
            }
        }

        private func commerce(parentID: String, isIAP: Bool, key: String) async throws -> [String: Any] {
            let parentPath = isIAP ? "/v2/inAppPurchases/\(parentID)" : "/v1/subscriptions/\(parentID)"
            let availabilityName = isIAP ? "inAppPurchaseAvailability" : "subscriptionAvailability"
            let availabilityType = isIAP ? "inAppPurchaseAvailabilities" : "subscriptionAvailabilities"
            var result: [String: Any] = [:]
            if let availability = try await single("\(parentPath)/\(availabilityName)") {
                try Self.checkResource(availability, type: availabilityType)
                let territories = try await list("/v1/\(availabilityType)/\(Self.id(availability))/availableTerritories", type: "territories")
                result["availability"] = Self.semantic(availability)
                result["territories"] = territories.map { Self.semantic($0) }
                if territories.isEmpty { issue(key, "availability_empty", status: "blocked") }
            } else { issue(key, "availability_missing", status: "blocked") }
            if isIAP {
                if let schedule = try await single("\(parentPath)/iapPriceSchedule?include=baseTerritory") {
                    try Self.checkResource(schedule, type: "inAppPurchasePriceSchedules")
                    let scheduleID = try Self.id(schedule)
                    let query = ["include": "inAppPurchasePricePoint,territory"]
                    let manual = try await list("/v1/inAppPurchasePriceSchedules/\(scheduleID)/manualPrices", type: "inAppPurchasePrices", query: query)
                    let automatic = try await list("/v1/inAppPurchasePriceSchedules/\(scheduleID)/automaticPrices", type: "inAppPurchasePrices", query: query)
                    result["schedule"] = Self.semantic(schedule, relationships: true)
                    result["manualPrices"] = manual.map { Self.semantic($0, relationships: true) }
                    result["automaticPrices"] = automatic.map { Self.semantic($0, relationships: true) }
                    if manual.isEmpty && automatic.isEmpty { issue(key, "prices_missing", status: "blocked") }
                    for price in manual + automatic { try Self.requirePricePoint(price, relationship: "inAppPurchasePricePoint", type: "inAppPurchasePricePoints") }
                } else { issue(key, "prices_missing", status: "blocked") }
            } else {
                let prices = try await list("\(parentPath)/prices", type: "subscriptionPrices", query: ["include": "subscriptionPricePoint,territory"])
                result["prices"] = prices.map { Self.semantic($0, relationships: true) }
                if prices.isEmpty { issue(key, "prices_missing", status: "blocked") }
                for price in prices { try Self.requirePricePoint(price, relationship: "subscriptionPricePoint", type: "subscriptionPricePoints") }
            }
            return result
        }

        private func iapAttachmentSatisfied(_ catalog: [[String: Any]]) async throws -> Bool {
            guard catalog.allSatisfy({ Self.iapTypes.contains(Self.text(Self.attributes($0)["inAppPurchaseType"])) &&
                Self.catalogStates.contains(Self.text(Self.attributes($0)["state"])) && !Self.text(Self.attributes($0)["productId"]).isEmpty }) else { return false }
            for kind in Self.iapTypes {
                let products = catalog.filter { Self.text(Self.attributes($0)["inAppPurchaseType"]) == kind }
                guard products.contains(where: { Self.text(Self.attributes($0)["state"]) == "READY_TO_SUBMIT" }) else { continue }
                if products.contains(where: { Self.text(Self.attributes($0)["state"]) == "APPROVED" }) || selectedIAPTypes.contains(kind) { continue }
                var approved = false
                for product in products {
                    if Self.approved(try await list("/v2/inAppPurchases/\(Self.id(product))/versions", type: "inAppPurchaseVersions")) { approved = true }
                }
                if !approved { return false }
            }
            return true
        }

        private func subscriptionAttachmentSatisfied(_ catalog: [[String: Any]]) async throws -> Bool {
            guard catalog.allSatisfy({ Self.catalogStates.contains(Self.text(Self.attributes($0)["state"])) &&
                !Self.text(Self.attributes($0)["productId"]).isEmpty }) else { return false }
            if !catalog.contains(where: { Self.text(Self.attributes($0)["state"]) == "READY_TO_SUBMIT" }) ||
                !selectedSubscriptionGroups.isEmpty || catalog.contains(where: { Self.text(Self.attributes($0)["state"]) == "APPROVED" }) { return true }
            for product in catalog {
                if Self.approved(try await list("/v1/subscriptions/\(Self.id(product))/versions", type: "subscriptionVersions")) { return true }
            }
            return false
        }

        private func issue(_ key: String, _ reason: String, status: String = "unverified", locale: String? = nil) {
            diagnostics.append(.init(id: "joint_review.\(key).\(reason)", status: status, source: "publicApi", reason: reason, locale: locale,
                guidance: "Die ausgewählten Produktversionen, Metadaten und Prüfbilder in App Store Connect vervollständigen und denselben Blitz-Auftrag erneut prüfen."))
        }

        private static let iapTypes = ["CONSUMABLE", "NON_CONSUMABLE", "NON_RENEWING_SUBSCRIPTION"]
        private static let catalogStates: Set<String> = ["MISSING_METADATA", "WAITING_FOR_UPLOAD", "PROCESSING_CONTENT", "READY_TO_SUBMIT", "WAITING_FOR_REVIEW", "IN_REVIEW", "DEVELOPER_ACTION_NEEDED", "PENDING_BINARY_APPROVAL", "APPROVED", "DEVELOPER_REMOVED_FROM_SALE", "REMOVED_FROM_SALE", "REJECTED"]
        private static let versionStates: Set<String> = ["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "ACCEPTED", "APPROVED", "REJECTED", "DEVELOPER_REJECTED", "REPLACED_WITH_NEW_VERSION"]
        private static func knownHistory(_ values: [[String: Any]]) -> Bool {
            var numbers: Set<Int> = []
            return values.allSatisfy { value in
                guard let number = attributes(value)["version"] as? Int, number > 0,
                      numbers.insert(number).inserted, versionStates.contains(text(attributes(value)["state"])) else { return false }
                return true
            }
        }
        private static func approved(_ values: [[String: Any]]) -> Bool {
            knownHistory(values) && values.contains { text(attributes($0)["state"]) == "APPROVED" }
        }
        private static func attributes(_ value: [String: Any]) -> [String: Any] { value["attributes"] as? [String: Any] ?? [:] }
        private static func text(_ value: Any?) -> String { (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        private static func id(_ value: [String: Any]) throws -> String {
            guard let id = value["id"] as? String, ReleaseWorkflowTarget.validID(id) else { throw ReleaseWorkflowAPIError.invalidResponse }
            return id
        }
        private static func checkResource(_ value: [String: Any], type: String) throws {
            _ = try id(value)
            guard value["type"] as? String == type, value["attributes"] == nil || value["attributes"] is [String: Any] else { throw ReleaseWorkflowAPIError.invalidResponse }
        }
        private static func index(_ values: [[String: Any]]) throws -> [String: [String: Any]] {
            var result: [String: [String: Any]] = [:]
            for value in values { result[try id(value)] = value }
            return result
        }
        private static func owner(_ value: [String: Any], relationship: String, type: String) throws -> String {
            guard let relations = value["relationships"] as? [String: [String: Any]],
                  let data = relations[relationship]?["data"] as? [String: Any], data["type"] as? String == type else {
                throw ReleaseWorkflowAPIError.invalidResponse
            }
            return try id(data)
        }
        private static func checkOptionalOwner(_ value: [String: Any], relationship: String, type: String, id: String) throws {
            if let relations = value["relationships"] as? [String: [String: Any]], relations[relationship]?["data"] != nil {
                guard try owner(value, relationship: relationship, type: type) == id else { throw ReleaseWorkflowError.identityChanged }
            }
        }
        private static func requirePricePoint(_ value: [String: Any], relationship: String, type: String) throws {
            _ = try owner(value, relationship: relationship, type: type)
            _ = try owner(value, relationship: "territory", type: "territories")
        }
        private static func semantic(_ value: [String: Any], relationships: Bool = false) -> [String: Any] {
            var result = value.filter { ["id", "type"].contains($0.key) }
            result["attributes"] = attributes(value).filter { !["state", "createdDate"].contains($0.key) }
            if relationships, let relations = value["relationships"] as? [String: [String: Any]] {
                result["relationships"] = relations.compactMapValues { $0["data"] }
            }
            return result
        }
        private static func assetSemantic(_ value: [String: Any]) -> [String: Any] {
            // Upload URLs/headers and expiring delivery URLs are neither content
            // identity nor journal material. The completed source checksum is.
            var result = semantic(value)
            result["attributes"] = attributes(value).filter { !["uploadOperations", "imageAsset", "assetDeliveryState"].contains($0.key) }
            return result
        }
    }
}
