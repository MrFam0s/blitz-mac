import CryptoKit
import Foundation
import Testing
@testable import Blitz

/// Shared public-API fixture for product inspection and full adapter tests.
/// Only synthetic identities are used; any unexpected read fails the test.
struct JointProductFixture {
    var singles: [String: [String: Any]] = [:]
    var lists: [String: [[String: Any]]] = [:]
    let appID: String
    static let allItems: [ReleaseReviewItem] = [
        .init(type: .inAppPurchaseVersions, id: "iap-version"),
        .init(type: .subscriptionVersions, id: "sub-version"),
        .init(type: .subscriptionGroupVersions, id: "group-version")]

    init(appID: String = "app1") {
        self.appID = appID
        let iap = Self.resource("inAppPurchases", "iap1", attrs: ["name": "Pro", "productId": "org.example.pro",
            "inAppPurchaseType": "NON_CONSUMABLE", "state": "READY_TO_SUBMIT", "reviewNote": "Unlock the feature"])
        let subscription = Self.resource("subscriptions", "sub1", attrs: ["name": "Monthly", "productId": "org.example.monthly",
            "state": "READY_TO_SUBMIT", "subscriptionPeriod": "ONE_MONTH", "groupLevel": 1])
        let group = Self.resource("subscriptionGroups", "group1", attrs: ["referenceName": "Membership"])
        lists["/v1/apps/\(appID)/inAppPurchasesV2"] = [iap]
        lists["/v1/apps/\(appID)/subscriptionGroups"] = [group]
        lists["/v1/subscriptionGroups/group1/subscriptions"] = [subscription]
        let definitions: [(String, String, String, String, String)] = [
            ("inAppPurchaseVersions", "iap-version", "inAppPurchase", "inAppPurchases", "iap1"),
            ("subscriptionVersions", "sub-version", "subscription", "subscriptions", "sub1"),
            ("subscriptionGroupVersions", "group-version", "subscriptionGroup", "subscriptionGroups", "group1")]
        for (type, id, relation, parentType, parentID) in definitions {
            let version = Self.resource(type, id, attrs: ["version": 1, "state": "PREPARE_FOR_SUBMISSION"],
                relationships: [relation: Self.link(parentType, parentID)])
            singles["/v1/\(type)/\(id)?include=\(relation)"] = version
            let prefix = parentType == "inAppPurchases" ? "/v2" : "/v1"
            lists["\(prefix)/\(parentType)/\(parentID)/versions"] = [version]
            let localizationType = type == "inAppPurchaseVersions" ? "inAppPurchaseLocalizations" :
                (type == "subscriptionVersions" ? "subscriptionLocalizations" : "subscriptionGroupLocalizations")
            lists["/v1/\(type)/\(id)/localizations"] = [Self.resource(localizationType, "loc-\(parentID)",
                attrs: ["locale": "de-DE", "name": "Premium", "description": "Mehr Funktionen"])]
            guard type != "subscriptionGroupVersions" else { continue }
            lists["/v1/\(type)/\(id)/images"] = []
            let reviewType = type == "inAppPurchaseVersions" ? "inAppPurchaseAppStoreReviewScreenshots" : "subscriptionAppStoreReviewScreenshots"
            singles["\(prefix)/\(parentType)/\(parentID)/appStoreReviewScreenshot"] = Self.resource(reviewType,
                "review-\(parentID)", attrs: ["fileName": "review.png", "fileSize": 100, "sourceFileChecksum": "checksum-\(parentID)",
                    "assetDeliveryState": ["state": "COMPLETE"], "imageAsset": ["templateUrl": "https://example.invalid/image"]])
            let availabilityName = type == "inAppPurchaseVersions" ? "inAppPurchaseAvailability" : "subscriptionAvailability"
            let availabilityType = type == "inAppPurchaseVersions" ? "inAppPurchaseAvailabilities" : "subscriptionAvailabilities"
            singles["\(prefix)/\(parentType)/\(parentID)/\(availabilityName)"] = Self.resource(availabilityType,
                "availability-\(parentID)", attrs: ["availableInNewTerritories": true])
            lists["/v1/\(availabilityType)/availability-\(parentID)/availableTerritories"] = [Self.resource("territories", "DEU", attrs: ["currency": "EUR"])]
        }
        singles["/v2/inAppPurchases/iap1/iapPriceSchedule?include=baseTerritory"] = Self.resource("inAppPurchasePriceSchedules", "schedule1", attrs: [:],
            relationships: ["baseTerritory": Self.link("territories", "DEU")])
        lists["/v1/inAppPurchasePriceSchedules/schedule1/manualPrices"] = [Self.resource("inAppPurchasePrices", "iap-price", attrs: ["manual": true],
            relationships: ["inAppPurchasePricePoint": Self.link("inAppPurchasePricePoints", "iap-point"), "territory": Self.link("territories", "DEU")])]
        lists["/v1/inAppPurchasePriceSchedules/schedule1/automaticPrices"] = []
        lists["/v1/subscriptions/sub1/prices"] = [Self.resource("subscriptionPrices", "sub-price", attrs: ["preserved": false],
            relationships: ["subscriptionPricePoint": Self.link("subscriptionPricePoints", "sub-point"), "territory": Self.link("territories", "DEU")])]
    }

    func target(items: [ReleaseReviewItem] = allItems) -> ReleaseWorkflowTarget {
        .init(projectID: "project", projectPath: "/tmp", appID: appID, bundleID: "org.example.App", platform: "IOS",
              accountKey: "issuer:key", versionID: "version1", buildID: "build8", reviewItems: items)
    }

    func inspect(items: [ReleaseReviewItem] = allItems) async throws -> ReleaseProductSelection.Result {
        try await ReleaseProductSelection.inspect(target: target(items: items), single: { singles[$0] }, all: { path, _ in
            guard let values = lists[path] else { throw ReleaseWorkflowAPIError.invalidResponse }
            return values
        })
    }

    /// Adapter transports may return this JSON API envelope before routing the
    /// remaining app/build/submission endpoints to their own fixtures.
    func response(for requestPath: String) -> [String: Any]? {
        let url = URL(string: "https://api.appstoreconnect.apple.com" + requestPath)!
        if let list = lists[url.path] { return ["data": list, "links": [:]] }
        if let single = singles[requestPath] { return ["data": single] }
        if let single = singles[url.path] { return ["data": single] }
        if url.path.hasSuffix("/image") && ["/v1/inAppPurchaseVersions/iap-version/image", "/v1/subscriptionVersions/sub-version/image"].contains(url.path) {
            return ["data": NSNull()]
        }
        return nil
    }

    mutating func setVersionState(_ state: String) {
        for key in Array(singles.keys) where key.contains("?include=") && key.contains("Versions/") {
            var resource = singles[key]!, attrs = resource["attributes"] as! [String: Any]
            attrs["state"] = state; resource["attributes"] = attrs; singles[key] = resource
        }
        for key in Array(lists.keys) where key.hasSuffix("/versions") {
            lists[key] = lists[key]!.map { value in
                var value = value, attrs = value["attributes"] as! [String: Any]
                attrs["state"] = state; value["attributes"] = attrs; return value
            }
        }
    }

    static func resource(_ type: String, _ id: String, attrs: [String: Any], relationships: [String: Any]? = nil) -> [String: Any] {
        var result: [String: Any] = ["type": type, "id": id, "attributes": attrs]
        if let relationships { result["relationships"] = relationships }
        return result
    }
    static func link(_ type: String, _ id: String) -> [String: Any] { ["data": ["type": type, "id": id]] }
    static func digest(_ value: ReleaseProductSelection.Result) throws -> String {
        SHA256.hash(data: try JSONSerialization.data(withJSONObject: value.protectedContent, options: [.sortedKeys]))
            .map { String(format: "%02x", $0) }.joined()
    }
}

@Test func jointProductSelectionReadsAllThreeKindsAndCompleteAttachmentScope() async throws {
    let result = try await JointProductFixture().inspect()
    #expect(result.diagnostics.isEmpty)
    #expect(result.protectedContent.count == 3)
    #expect(result.attachmentEvidence.count == 2)
}

@Test func jointProductSelectionRejectsForeignParentAndAmbiguousParentVersions() async throws {
    var foreign = JointProductFixture()
    var version = foreign.singles["/v1/inAppPurchaseVersions/iap-version?include=inAppPurchase"]!
    version["relationships"] = ["inAppPurchase": JointProductFixture.link("inAppPurchases", "foreign-parent")]
    foreign.singles["/v1/inAppPurchaseVersions/iap-version?include=inAppPurchase"] = version
    await #expect(throws: ReleaseWorkflowError.self) { try await foreign.inspect() }
    var duplicate = JointProductFixture()
    var second = duplicate.singles["/v1/inAppPurchaseVersions/iap-version?include=inAppPurchase"]!
    second["id"] = "iap-zsecond"
    duplicate.singles["/v1/inAppPurchaseVersions/iap-zsecond?include=inAppPurchase"] = second
    duplicate.lists["/v2/inAppPurchases/iap1/versions"]!.append(second)
    await #expect(throws: ReleaseWorkflowError.self) {
        try await duplicate.inspect(items: JointProductFixture.allItems + [.init(type: .inAppPurchaseVersions, id: "iap-zsecond")])
    }
}

@Test func jointProductSelectionRequiresGroupAndSubscriptionTogetherUntilApproved() async throws {
    let fixture = JointProductFixture()
    let withoutGroup = try await fixture.inspect(items: JointProductFixture.allItems.filter { $0.type != .subscriptionGroupVersions })
    #expect(withoutGroup.diagnostics.contains { $0.reason == "unapproved_group_version_not_selected" && $0.status == "blocked" })
    #expect(withoutGroup.attachmentEvidence.isEmpty)
    let withoutSubscription = try await fixture.inspect(items: JointProductFixture.allItems.filter { $0.type != .subscriptionVersions })
    #expect(withoutSubscription.diagnostics.contains { $0.reason == "new_group_requires_selected_subscription" })
    var approved = fixture
    var currentGroup = approved.lists["/v1/subscriptionGroups/group1/versions"]![0]
    currentGroup["attributes"] = ["version": 2, "state": "PREPARE_FOR_SUBMISSION"]
    approved.lists["/v1/subscriptionGroups/group1/versions"] = [currentGroup]
    approved.lists["/v1/subscriptionGroups/group1/versions"]!.append(JointProductFixture.resource("subscriptionGroupVersions", "approved-group",
        attrs: ["version": 1, "state": "APPROVED"]))
    // Existing approval is sufficient for a subscription whose group is not in
    // the selected set; no implicit group version is submitted.
    let existing = try await approved.inspect(items: JointProductFixture.allItems.filter { $0.type != .subscriptionGroupVersions })
    #expect(existing.diagnostics.isEmpty)
    approved.lists["/v1/subscriptionGroups/group1/versions"]![1]["attributes"] = ["version": 0, "state": "APPROVED"]
    let malformed = try await approved.inspect(items: JointProductFixture.allItems.filter { $0.type != .subscriptionGroupVersions })
    #expect(malformed.diagnostics.contains { $0.reason == "group_history_unverified" })
    #expect(malformed.attachmentEvidence.isEmpty)
}

@Test func jointProductSelectionDoesNotWaiveUnselectedFirstPurchaseTypes() async throws {
    var fixture = JointProductFixture()
    fixture.lists["/v1/apps/app1/inAppPurchasesV2"]!.append(JointProductFixture.resource("inAppPurchases", "coins",
        attrs: ["name": "Coins", "productId": "org.example.coins", "inAppPurchaseType": "CONSUMABLE", "state": "READY_TO_SUBMIT"]))
    fixture.lists["/v2/inAppPurchases/coins/versions"] = []
    let result = try await fixture.inspect()
    #expect(result.attachmentEvidence["iap.first_type_app_version_attachment"] == nil)
    #expect(result.diagnostics.contains { $0.reason == "iap_attachment_coverage_unverified" })
    fixture.lists["/v1/apps/app1/inAppPurchasesV2"]![1]["attributes"] = ["productId": "org.example.coins", "inAppPurchaseType": "CONSUMABLE", "state": "UNKNOWN"]
    let unknown = try await fixture.inspect()
    #expect(unknown.attachmentEvidence["iap.first_type_app_version_attachment"] == nil)
}

@Test func jointProductSelectionBlocksMissingMetadataAndIncompleteReviewMedia() async throws {
    var fixture = JointProductFixture()
    fixture.lists["/v1/inAppPurchaseVersions/iap-version/localizations"] = []
    var screenshot = fixture.singles["/v1/subscriptions/sub1/appStoreReviewScreenshot"]!
    screenshot["attributes"] = ["fileName": "review.png", "fileSize": 100, "assetDeliveryState": ["state": "UPLOAD_COMPLETE"]]
    fixture.singles["/v1/subscriptions/sub1/appStoreReviewScreenshot"] = screenshot
    let result = try await fixture.inspect()
    #expect(result.diagnostics.contains { $0.reason == "localizations_missing" && $0.status == "blocked" })
    #expect(result.diagnostics.contains { $0.reason == "review_screenshot_not_complete" && $0.status == "unverified" })
    #expect(result.diagnostics.contains { $0.reason == "review_screenshot_content_unverified" })
    #expect(result.attachmentEvidence.isEmpty)
}

@Test func jointProductFingerprintAllowsLifecycleButProtectsTextImagesAndPricing() async throws {
    var fixture = JointProductFixture()
    let initial = try JointProductFixture.digest(await fixture.inspect())
    fixture.setVersionState("READY_FOR_REVIEW")
    #expect(try JointProductFixture.digest(await fixture.inspect()) == initial)
    fixture.setVersionState("WAITING_FOR_REVIEW")
    let submitted = try await fixture.inspect()
    #expect(try JointProductFixture.digest(submitted) == initial)
    #expect(submitted.diagnostics.contains { $0.reason == "version_not_editable" })

    var imageChanged = fixture
    var screenshot = imageChanged.singles["/v2/inAppPurchases/iap1/appStoreReviewScreenshot"]!
    var attrs = screenshot["attributes"] as! [String: Any]; attrs["sourceFileChecksum"] = "replacement"
    screenshot["attributes"] = attrs; imageChanged.singles["/v2/inAppPurchases/iap1/appStoreReviewScreenshot"] = screenshot
    #expect(try JointProductFixture.digest(await imageChanged.inspect()) != initial)

    var textChanged = fixture
    textChanged.lists["/v1/subscriptionVersions/sub-version/localizations"]![0]["attributes"] = ["locale": "de-DE", "name": "Changed", "description": "Changed"]
    #expect(try JointProductFixture.digest(await textChanged.inspect()) != initial)

    var priceChanged = fixture
    priceChanged.lists["/v1/subscriptions/sub1/prices"]![0]["relationships"] = [
        "subscriptionPricePoint": JointProductFixture.link("subscriptionPricePoints", "other-price"),
        "territory": JointProductFixture.link("territories", "DEU")]
    #expect(try JointProductFixture.digest(await priceChanged.inspect()) != initial)
}

@Test func jointProductFingerprintIgnoresExpiringMediaURLsButNeverStoresUploadHeaders() async throws {
    var fixture = JointProductFixture()
    let initial = try JointProductFixture.digest(await fixture.inspect())
    var screenshot = fixture.singles["/v2/inAppPurchases/iap1/appStoreReviewScreenshot"]!
    var attrs = screenshot["attributes"] as! [String: Any]
    attrs["imageAsset"] = ["templateUrl": "https://example.invalid/renewed"]
    attrs["uploadOperations"] = [["requestHeaders": [["name": "Authorization", "value": "PRIVATE_TEST_VALUE"]]]]
    screenshot["attributes"] = attrs; fixture.singles["/v2/inAppPurchases/iap1/appStoreReviewScreenshot"] = screenshot
    let result = try await fixture.inspect()
    #expect(try JointProductFixture.digest(result) == initial)
    let data = try JSONSerialization.data(withJSONObject: result.protectedContent, options: [.sortedKeys])
    #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE_TEST_VALUE"))
}

@Test(arguments: ["/v2/inAppPurchases/iap1/appStoreReviewScreenshot", "/v1/subscriptions/sub1/appStoreReviewScreenshot"])
func jointProductFingerprintAllowsRotatingTokensOnlyWithSourceChecksum(path: String) async throws {
    var fixture = JointProductFixture()
    var screenshot = fixture.singles[path]!
    var attrs = screenshot["attributes"] as! [String: Any]
    attrs["assetToken"] = "first-delivery-token"
    screenshot["attributes"] = attrs; fixture.singles[path] = screenshot
    let before = try await fixture.inspect()
    #expect(before.diagnostics.isEmpty)
    let initial = try JointProductFixture.digest(before)

    attrs["assetToken"] = "rotated-delivery-token"
    screenshot["attributes"] = attrs; fixture.singles[path] = screenshot
    let after = try await fixture.inspect()
    #expect(after.diagnostics.isEmpty)
    #expect(try JointProductFixture.digest(after) == initial)

    // Content identity remains protected even when delivery tokens are ignored.
    for field in ["sourceFileChecksum", "fileSize", "id"] {
        var changed = fixture, replacement = screenshot, changedAttributes = attrs
        if field == "id" { replacement["id"] = "replacement-review-image" }
        else if field == "fileSize" { changedAttributes[field] = 101 }
        else { changedAttributes[field] = "replacement-checksum" }
        replacement["attributes"] = changedAttributes; changed.singles[path] = replacement
        #expect(try JointProductFixture.digest(await changed.inspect()) != initial)
    }
}

@Test(arguments: ["/v2/inAppPurchases/iap1/appStoreReviewScreenshot", "/v1/subscriptions/sub1/appStoreReviewScreenshot"])
func jointProductFingerprintProtectsTokenWhenChecksumMissingOrBlank(path: String) async throws {
    for checksum in [nil, "", " \t\n"] as [String?] {
        var fixture = JointProductFixture()
        var screenshot = fixture.singles[path]!
        var attrs = screenshot["attributes"] as! [String: Any]
        attrs["sourceFileChecksum"] = checksum
        attrs["assetToken"] = "first-content-token"
        screenshot["attributes"] = attrs; fixture.singles[path] = screenshot
        let before = try await fixture.inspect()
        #expect(before.diagnostics.isEmpty)
        let initial = try JointProductFixture.digest(before)

        attrs["assetToken"] = "replacement-content-token"
        screenshot["attributes"] = attrs; fixture.singles[path] = screenshot
        #expect(try JointProductFixture.digest(await fixture.inspect()) != initial)

        // Missing/whitespace checksums cannot certify an image without a token.
        attrs["assetToken"] = " \t\n"
        screenshot["attributes"] = attrs; fixture.singles[path] = screenshot
        let unverifiable = try await fixture.inspect()
        #expect(unverifiable.diagnostics.contains { $0.reason == "review_screenshot_content_unverified" })
        #expect(unverifiable.attachmentEvidence.isEmpty)
    }
}

@Test func jointProductSelectionAcceptsCompletedV2ImagesWithAssetTokenWithoutChecksum() async throws {
    var fixture = JointProductFixture()
    fixture.lists["/v1/inAppPurchaseVersions/iap-version/images"] = [JointProductFixture.resource("inAppPurchaseImages", "promo-iap",
        attrs: ["fileSize": 200, "fileName": "promo.png", "assetToken": "stable-content-token", "assetDeliveryState": ["state": "COMPLETE"]])]
    fixture.lists["/v1/subscriptionVersions/sub-version/images"] = [JointProductFixture.resource("subscriptionImages", "promo-sub",
        attrs: ["fileSize": 300, "fileName": "promo.png", "assetToken": "other-token", "assetDeliveryState": ["state": "COMPLETE"]])]
    let result = try await fixture.inspect()
    #expect(result.diagnostics.isEmpty)
    #expect(result.attachmentEvidence.count == 2)
    var promoted = fixture
    promoted.singles["/v1/inAppPurchaseVersions/iap-version/image"] = fixture.lists["/v1/inAppPurchaseVersions/iap-version/images"]![0]
    #expect(try JointProductFixture.digest(await promoted.inspect()) != JointProductFixture.digest(result))
}

@Test func jointProductSelectionDoesNotTreatConflictingVersionStatesAsReady() async throws {
    var fixture = JointProductFixture()
    fixture.lists["/v2/inAppPurchases/iap1/versions"]![0]["attributes"] = ["version": 1, "state": "APPROVED"]
    let result = try await fixture.inspect()
    #expect(result.diagnostics.contains { $0.reason == "version_state_changed_during_read" && $0.status == "unverified" })
    #expect(result.attachmentEvidence.isEmpty)
}

@Test func jointProductSelectionRejectsSupersededAndUnknownVersionHistories() async throws {
    var fixture = JointProductFixture()
    fixture.lists["/v2/inAppPurchases/iap1/versions"]!.append(JointProductFixture.resource("inAppPurchaseVersions", "newer", attrs: ["version": 2, "state": "PREPARE_FOR_SUBMISSION"]))
    #expect(try await fixture.inspect().diagnostics.contains { $0.reason == "version_superseded_or_ambiguous" })
    fixture.lists["/v2/inAppPurchases/iap1/versions"]![1]["attributes"] = ["version": 2, "state": "UNKNOWN"]
    #expect(try await fixture.inspect().diagnostics.contains { $0.reason == "version_history_unverified" })
}

@Test func jointProductReadinessReplacesOnlyProvenAttachmentChecks() async throws {
    let fixture = JointProductFixture(), products = try await fixture.inspect()
    let checks: [[String: Any]] = [
        ["id": "iap.first_type_app_version_attachment", "severity": "error"],
        ["id": "subscriptions.first_type_app_version_attachment.missing", "severity": "error"],
        ["id": "subscriptions.diagnostics.review_screenshot_missing", "severity": "warning", "resourceId": "unselected"]]
    let deepChecks: [[String: Any]] = [
        ["id": "iap.first_type_app_version_attachment", "status": "blocked", "source": "publicApi"],
        ["id": "subscriptions.first_type_app_version_attachment", "status": "blocked", "source": "webSession"]]
    let report: [String: Any] = ["appId": "app1", "versionId": "version1", "platform": "IOS", "checks": checks,
        "summary": ["blocking": 3, "warnings": 1], "deep": ["checks": deepChecks, "summary": ["blocked": 2, "unverified": 0]]]
    let check = ReleaseWebEvidence.Check(status: "passed", reason: "fixture")
    let web = ReleaseWebEvidence(appId: "app1", bundleId: "org.example.App", bindingVerified: true, bindingReason: "fixture",
        appleId: "test@example.invalid", providerId: "provider", programLicense: check, businessFree: check, businessPaid: check)
    let result = try ReleaseReadinessPolicy.normalize(report: report, exitCode: 1, target: fixture.target(), firstPublication: true,
        localizations: [], web: web, webBindingStable: true, products: products)
    #expect(!result.ready && result.blocking == 1 && result.warnings == 1)
    #expect(result.diagnostics?.contains { $0.id == "iap.first_type_app_version_attachment" && $0.status == "passed" } == true)
    #expect(result.checkIDs.contains("subscriptions.diagnostics.review_screenshot_missing"))

    var partial = report; partial["summary"] = ["blocking": 2, "warnings": 1]
    #expect(throws: ReleaseWorkflowAPIError.self) {
        try ReleaseReadinessPolicy.normalize(report: partial, exitCode: 1, target: fixture.target(), firstPublication: true,
            localizations: [], web: web, webBindingStable: true, products: products)
    }
}
