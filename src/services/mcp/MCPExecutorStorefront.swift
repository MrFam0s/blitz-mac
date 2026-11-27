import Foundation

extension MCPRegistry {
    static func storefrontTools() -> [[String: Any]] {
        [
            storeTool(name: "store_availability_get",
                      description: "Read the app-wide storefront selection against Apple's complete current territory catalog. Reports enabled, disabled and unknown countries, whether all current countries are selected, and the separate setting for future countries. Selection is distinct from actual sale or release status.",
                      properties: [:], required: []),
            storeTool(name: "store_availability_set",
                      description: "Set the app-wide availability flag for named current storefronts or all current storefronts. Requires explicit authorization for the selection. Reads Apple's settings back, including after a partial failure. First setup additionally requires an explicit future-territory policy and an enabled selection; countries outside that initial selection start disabled.",
                      properties: [
                        "territoryCodes": ["type": "array", "minItems": 1, "uniqueItems": true,
                                           "items": ["type": "string", "pattern": "^[A-Z]{3}$"],
                                           "description": "Apple's three-letter storefront codes. Omit when selecting all current territories." ] as [String: Any],
                        "allCurrentTerritories": ["type": "boolean", "description": "Use true only when all current countries are explicitly in scope."],
                        "available": ["type": "boolean"],
                        "confirm": ["type": "boolean", "description": "True when the user authorized this exact app-wide change."],
                        "initialAvailableInNewTerritories": ["type": "boolean", "description": "First configuration only. Explicitly choose whether newly introduced storefronts should be enabled. When configuration already exists, a supplied value must match the current policy."]
                      ], required: ["available", "confirm"])
        ]
    }
}

struct StorefrontSelection {
    let territoryCodes: Set<String>?
    let available: Bool
    let initialFutureAvailability: Bool?

    init(arguments: [String: Any]) throws {
        let invalid = MCPServerService.MCPError.invalidToolArgs
        guard arguments["available"] != nil, try ReleaseWorkflowArguments.optionalBoolean("confirm", arguments: arguments) else { throw invalid }
        available = try ReleaseWorkflowArguments.optionalBoolean("available", arguments: arguments)
        initialFutureAvailability = try arguments["initialAvailableInNewTerritories"] == nil ? nil :
            ReleaseWorkflowArguments.optionalBoolean("initialAvailableInNewTerritories", arguments: arguments)
        if arguments["allCurrentTerritories"] != nil {
            guard try ReleaseWorkflowArguments.optionalBoolean("allCurrentTerritories", arguments: arguments),
                  arguments["territoryCodes"] == nil else { throw invalid }
            territoryCodes = nil
        } else {
            guard let list = arguments["territoryCodes"] as? [String], !list.isEmpty,
                  list.allSatisfy(Self.validCode), Set(list).count == list.count else { throw invalid }
            territoryCodes = Set(list)
        }
    }

    static func validCode(_ value: String) -> Bool {
        value.utf8.count == 3 && value.utf8.allSatisfy { (65...90).contains($0) }
    }
}

extension MCPExecutor {
    func executeStorefrontTool(name: String, arguments: [String: Any], context: MCPStoreContext) async throws -> [String: Any] {
        switch name {
        case "store_availability_get":
            let snapshot = try await context.service.storefronts(appID: context.appID, validate: context.validate)
            return mcpJSON(snapshot.payload)
        case "store_availability_set":
            let selection = try StorefrontSelection(arguments: arguments)
            let result = try await context.service.updateStorefronts(appID: context.appID, selection: selection, validate: context.validate)
            var response = mcpJSON(result)
            if result["verified"] as? Bool != true { response["isError"] = true }
            return response
        default: throw MCPServerService.MCPError.invalidToolArgs
        }
    }
}
