import Foundation
import Testing
@testable import Blitz

struct ReleaseWorkflowArgumentsTests {
    @Test func productSelectionAcceptsOnlyExactKnownVersionKinds() throws {
        let values: [[String: Any]] = [
            ["type": "subscriptionVersions", "id": "sub-version"],
            ["type": "inAppPurchaseVersions", "id": "iap-version"],
            ["type": "subscriptionGroupVersions", "id": "group-version"]]
        let items = try ReleaseWorkflowArguments.reviewItems(["reviewItems": values])
        #expect(items.map(\.key) == ["inAppPurchaseVersions:iap-version", "subscriptionGroupVersions:group-version", "subscriptionVersions:sub-version"])
        #expect(try ReleaseWorkflowArguments.reviewItems([:]).isEmpty)
        #expect(try ReleaseWorkflowArguments.reviewItems(["reviewItems": []]).isEmpty)
    }

    @Test func productSelectionRejectsParentResourcesMalformedOrDuplicateItems() {
        let invalid: [Any] = [NSNull(), "all", ["iap-version"],
            [["type": "inAppPurchases", "id": "parent"]],
            [["type": "subscriptions", "id": "parent"]],
            [["type": "appStoreVersions", "id": "another-app"]],
            [["type": "subscriptionVersions", "id": ""]],
            [["type": "subscriptionVersions", "id": "../foreign"]],
            [["type": "subscriptionVersions", "id": "sub", "productId": "ignored"]],
            [["type": "subscriptionVersions", "id": "sub"], ["type": "subscriptionVersions", "id": "sub"]],
            [["type": "subscriptionVersions", "id": 123]]]
        for value in invalid {
            #expect(throws: MCPServerService.MCPError.self) {
                try ReleaseWorkflowArguments.reviewItems(["reviewItems": value])
            }
        }
        let excess = (0..<200).map { ["type": "inAppPurchaseVersions", "id": "v-\($0)"] }
        #expect(throws: MCPServerService.MCPError.self) {
            try ReleaseWorkflowArguments.reviewItems(["reviewItems": excess])
        }
        #expect(throws: Never.self) {
            try ReleaseWorkflowArguments.reviewItems(["reviewItems": Array(excess.prefix(199))])
        }
    }

    @Test func savedOperationsCannotBeRetargetedThroughIgnoredArguments() throws {
        for name in ["release_status", "release_validate", "release_submit", "release_prepare_draft_refresh"] {
            for key in ["reviewItems", "appId", "versionId", "buildId", "platform", "releaseMode"] {
                #expect(throws: MCPServerService.MCPError.self) {
                    try ReleaseWorkflowArguments.validateKeys(name: name, arguments: [
                        "operationId": "operation", "accountKey": "account", key: "replacement"])
                }
            }
            try ReleaseWorkflowArguments.validateKeys(name: name, arguments: [
                "operationId": "operation", "accountKey": "account", "releaseTargetId": "assertion"])
        }
        #expect(throws: MCPServerService.MCPError.self) {
            try ReleaseWorkflowArguments.validateKeys(name: "release_prepare", arguments: ["reviewItem": []])
        }
    }

    @Test func schemaPublishesVersionSelectionOnlyDuringPreparation() throws {
        let tools = MCPRegistry.allTools()
        let prepare = try #require(tools.first { $0["name"] as? String == "release_prepare" })
        let schema = try #require(prepare["inputSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let selection = try #require(properties["reviewItems"] as? [String: Any])
        #expect(selection["maxItems"] as? Int == 199)
        let item = try #require(selection["items"] as? [String: Any])
        #expect(item["required"] as? [String] == ["type", "id"])
        #expect(item["additionalProperties"] as? Bool == false)
        for name in ["release_prepare", "release_validate", "release_status", "release_submit"] {
            let entry = try #require(tools.first { $0["name"] as? String == name })
            let input = try #require(entry["inputSchema"] as? [String: Any])
            #expect(input["additionalProperties"] as? Bool == false)
            if name != "release_prepare" {
                #expect((input["properties"] as? [String: Any])?["reviewItems"] == nil)
            }
        }
    }
}

@MainActor @Test func productOverviewUsesSelectionGuidanceForFirstAndLaterReleases() throws {
    for state in ["PREPARE_FOR_SUBMISSION", "READY_FOR_SALE"] {
        let manager = ASCManager()
        manager.appStoreVersions = [ASCAppStoreVersion(id: "version", attributes: .init(
            versionString: "1.0", appStoreState: state, releaseType: nil, createdDate: nil,
            copyright: nil, platform: "IOS"))]
        manager.inAppPurchases = [try JSONDecoder().decode(ASCInAppPurchase.self, from:
            Data(#"{"id":"purchase","attributes":{"name":"Extra","productId":"org.example.extra","state":"READY_TO_SUBMIT"}}"#.utf8))]
        let row = try #require(manager.submissionReadiness.fields.first { $0.label == "In-App Purchases & Subscriptions" })
        #expect(!row.required)
        #expect(row.value == nil)
        #expect(row.hint?.contains("release_prepare.reviewItems") == true)
        #expect(row.hint?.contains("iris API") == false)
    }
}


@Test func resubmissionPreparationArgumentsCannotRetargetSavedOperation() throws {
    let values: [String: Any] = ["operationId": "old", "accountKey": "issuer:key", "submissionId": "review"]
    try ReleaseWorkflowArguments.validateKeys(name: "release_prepare_resubmission", arguments: values)
    for key in ["appId", "buildId", "reviewItems", "releaseMode", "confirmLegacyDraftRecovery", "resumeSubmissionId"] {
        var invalid = values; invalid[key] = "foreign"
        #expect(throws: (any Error).self) {
            try ReleaseWorkflowArguments.validateKeys(name: "release_prepare_resubmission", arguments: invalid)
        }
    }
    let tools = MCPRegistry.allTools()
    let tool = try #require(tools.first { $0["name"] as? String == "release_prepare_resubmission" })
    let schema = try #require(tool["inputSchema"] as? [String: Any])
    #expect(schema["additionalProperties"] as? Bool == false)
    #expect(MCPRegistry.category(for: "release_prepare_resubmission") == .query)
}

@Test func rejectedItemResolutionRequiresAnExplicitBooleanPlan() throws {
    #expect(try !ReleaseWorkflowArguments.optionalBoolean("resolveRejectedItems", arguments: [:]))
    #expect(try ReleaseWorkflowArguments.optionalBoolean("resolveRejectedItems", arguments: ["resolveRejectedItems": true]))
    for key in ["resolveRejectedItems", "confirm", "confirmLegacyDraftRecovery"] {
        for invalid: Any in ["true", 1, NSNull(), ["item"]] {
            #expect(throws: (any Error).self) {
                try ReleaseWorkflowArguments.optionalBoolean(key, arguments: [key: invalid])
            }
        }
    }
    for name in ["release_status", "release_validate", "release_submit"] {
        #expect(throws: (any Error).self) {
            try ReleaseWorkflowArguments.validateKeys(name: name, arguments: ["resolveRejectedItems": true])
        }
    }
    let tool = try #require(MCPRegistry.allTools().first { $0["name"] as? String == "release_prepare_resubmission" })
    let schema = try #require(tool["inputSchema"] as? [String: Any])
    let properties = try #require(schema["properties"] as? [String: Any])
    #expect((properties["resolveRejectedItems"] as? [String: Any])?["type"] as? String == "boolean")
}


@Test func draftRefreshRequiresExactOperationAndDoesNotAcceptMutations() throws {
    let name = "release_prepare_draft_refresh"
    let required = ["operationId", "accountKey", "submissionId", "confirmationDigest"]
    let values = Dictionary(uniqueKeysWithValues: required.map { ($0, "saved") })
    try ReleaseWorkflowArguments.validateKeys(name: name, arguments: values)
    for key in ["confirm", "resolveRejectedItems", "resumeSubmissionId", "sharedLocation", "datingAndRelationships"] {
        var invalid = values
        invalid[key] = "value"
        #expect(throws: MCPServerService.MCPError.self) {
            try ReleaseWorkflowArguments.validateKeys(name: name, arguments: invalid)
        }
    }
    let tool = try #require(MCPRegistry.allTools().first { $0["name"] as? String == name })
    let schema = try #require(tool["inputSchema"] as? [String: Any])
    #expect(schema["additionalProperties"] as? Bool == false)
    #expect(Set(schema["required"] as? [String] ?? []) == Set(required))
    #expect(MCPRegistry.category(for: name) == .query)
}
