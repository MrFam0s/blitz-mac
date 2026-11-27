import Foundation

extension MCPRegistry {
    static let storeTools = chinaTools() + previewTools() + storefrontTools()
    static func isStoreTool(_ name: String) -> Bool { storeTools.contains { $0["name"] as? String == name } }

    static func storeTool(name: String, description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        let id = ["type": "string", "minLength": 1] as [String: Any]
        let target: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["projectId": id, "releaseTargetId": id, "appId": id, "bundleId": id, "platform": id, "versionId": id],
            "required": ["projectId", "appId", "bundleId", "platform"] + (name.hasPrefix("store_preview") ? ["versionId"] : [])
        ]
        var fields = properties
        fields["target"] = target
        fields["operationId"] = id
        fields["accountKey"] = id
        return ["name": name, "description": description + " Pass accountKey and exactly one of operationId (existing release) or target (registered project target).",
                "inputSchema": ["type": "object", "properties": fields, "required": ["accountKey"] + required, "additionalProperties": false] as [String: Any]]
    }
}

enum MCPStoreArguments {
    static func validate(_ name: String, _ args: [String: Any]) throws {
        guard let tool = MCPRegistry.storeTools.first(where: { $0["name"] as? String == name }),
              let schema = tool["inputSchema"] as? [String: Any] else { throw MCPServerService.MCPError.invalidToolArgs }
        try validateObject(args, schema)
        guard (args["operationId"] != nil) != (args["target"] != nil) else { throw ReleaseWorkflowError.invalidTarget }
        if let id = args["operationId"] as? String, UUID(uuidString: id) == nil { throw ReleaseWorkflowError.unknownOperation }
        if let target = args["target"] as? [String: Any] {
            for key in ["releaseTargetId", "appId", "versionId"] {
                if let value = target[key] as? String, !ReleaseWorkflowTarget.validID(value) { throw ReleaseWorkflowError.invalidTarget }
            }
        }
        if args["confirm"] != nil, try !ReleaseWorkflowArguments.optionalBoolean("confirm", arguments: args) {
            throw ReleaseWorkflowError.confirmationRequired
        }
    }

    private static func validateObject(_ args: [String: Any], _ schema: [String: Any]) throws {
        let invalid = MCPServerService.MCPError.invalidToolArgs
        guard let properties = schema["properties"] as? [String: Any],
              Set(args.keys).isSubset(of: properties.keys),
              Set(schema["required"] as? [String] ?? []).isSubset(of: args.keys) else { throw invalid }
        for (key, value) in args {
            guard let field = properties[key] as? [String: Any] else { throw invalid }
            switch field["type"] as? String {
            case "string":
                guard let string = value as? String, !string.isEmpty,
                      !string.utf8.contains(0), string == string.trimmingCharacters(in: .whitespacesAndNewlines),
                      (field["enum"] as? [String])?.contains(string) != false else { throw invalid }
            case "boolean": _ = try ReleaseWorkflowArguments.optionalBoolean(key, arguments: args)
            case "array": guard value is [String] else { throw invalid }
            case "object":
                guard let object = value as? [String: Any] else { throw invalid }
                try validateObject(object, field)
            default: throw invalid
            }
        }
    }
}

struct MCPStoreContext {
    let appID: String
    let bundleID: String
    let platform: String
    let accountKey: String
    let versionID: String?
    let projectRoot: URL
    let credentials: ASCCredentials
    let service: AppStoreConnectService
    let validate: () async throws -> Void
}

extension MCPExecutor {
    func executeStoreTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        try MCPStoreArguments.validate(name, arguments)
        guard let accountKey = arguments["accountKey"] as? String else { throw ReleaseWorkflowError.invalidTarget }
        let (credentials, revision) = try await MainActor.run { () throws -> (ASCCredentials, Int) in
            guard let creds = appState.ascManager.credentials, DashboardSummaryStore.accountKey(for: creds) == accountKey else {
                throw ReleaseWorkflowError.accountChanged
            }
            return (creds, appState.ascManager.credentialActivationRevision)
        }
        let journal = ReleaseWorkflowService(directory: BlitzPaths.root.appendingPathComponent("release-operations"),
                                            api: ReleaseWorkflowASCAdapter(credentials: credentials))
        let operation: ReleaseWorkflowRecord?
        let projectID: String, appID: String, bundleID: String, platform: String
        let versionID: String?, selectionID: String?
        if let id = arguments["operationId"] as? String {
            let record = try await journal.loadRecord(operationID: id)
            guard record.target.accountKey == accountKey else { throw ReleaseWorkflowError.accountChanged }
            operation = record
            projectID = record.target.projectID
            appID = record.target.appID
            bundleID = record.target.bundleID
            platform = record.target.platform
            versionID = record.target.versionID
            selectionID = record.target.releaseTargetID
        } else if let target = arguments["target"] as? [String: String], let project = target["projectId"],
                  let app = target["appId"], let bundle = target["bundleId"], let requestedPlatform = target["platform"] {
            operation = nil
            projectID = project
            appID = app
            bundleID = bundle
            platform = requestedPlatform
            versionID = target["versionId"]
            selectionID = target["releaseTargetId"]
        } else { throw ReleaseWorkflowError.invalidTarget }

        let project = try await Self.registeredReleaseProject(projectID)
        if let operation { try RegisteredReleaseTarget.verify(operation.target, project: project) }
        let registered = try RegisteredReleaseTarget.resolve(project: project, releaseTargetID: selectionID, appID: appID,
                                                              bundleID: bundleID, platform: platform, accountKey: accountKey)
        let root = URL(fileURLWithPath: project.path).resolvingSymlinksInPath()
        let service = AppStoreConnectService(credentials: credentials)
        let validate: () async throws -> Void = { [appState] in
            try await MCPMutationScope.checkBeforeWrite()
            try await MainActor.run {
                guard appState.ascManager.credentialActivationRevision == revision,
                      DashboardSummaryStore.accountKey(for: appState.ascManager.credentials) == accountKey else {
                    throw ReleaseWorkflowError.accountChanged
                }
            }
            let current = try await Self.registeredReleaseProject(projectID)
            guard URL(fileURLWithPath: current.path).resolvingSymlinksInPath() == root else { throw ReleaseWorkflowError.identityChanged }
            _ = try RegisteredReleaseTarget.resolve(project: current, releaseTargetID: registered.id, appID: appID,
                                                    bundleID: bundleID, platform: platform, accountKey: accountKey)
        }
        let context = MCPStoreContext(appID: appID, bundleID: bundleID, platform: platform, accountKey: accountKey,
                                      versionID: versionID, projectRoot: root, credentials: credentials, service: service, validate: validate)
        let preview = name.hasPrefix("store_preview")
        let writing = arguments["confirm"] != nil
        let run = {
            try await validate()
            let apple = try await service.fetchApp(id: appID)
            guard apple.id == appID, apple.bundleId == bundleID else { throw ReleaseWorkflowError.identityChanged }
            if let versionID {
                let versions = try await service.fetchAppStoreVersions(appId: appID)
                guard let version = versions.first(where: { $0.id == versionID }), version.attributes.platform == platform else {
                    throw ReleaseWorkflowError.identityChanged
                }
                if preview && writing && !ASCReleaseStatus.isEditable(version.attributes.effectiveState) { throw ReleaseWorkflowError.unsafeState }
                if let operation {
                    let build = try await service.fetchBuildAttachedToVersion(versionId: versionID)
                    guard build?.id == operation.target.buildID else { throw ReleaseWorkflowError.identityChanged }
                }
            }
            if preview { return try await self.executePreviewTool(name: name, arguments: arguments, context: context) }
            if name.hasPrefix("store_china_") { return try await self.executeChinaTool(name: name, arguments: arguments, context: context) }
            return try await self.executeStorefrontTool(name: name, arguments: arguments, context: context)
        }
        if writing {
            return try await journal.withStoreEdit(account: accountKey, app: appID, platform: platform, appWide: !preview,
                                                   operationID: operation?.operationID, edit: run)
        }
        return try await run()
    }
}
