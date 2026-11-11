import Foundation

extension MCPExecutor {
    /// No UI navigation or selected-version fallback is involved in these calls.
    /// CLI and MCP invoke this same durable, account-bound release backend.
    func executeReleaseWorkflow(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        func string(_ key: String) throws -> String {
            guard let value = arguments[key] as? String, !value.isEmpty,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw MCPServerService.MCPError.invalidToolArgs
            }
            return value
        }
        let accountKey = try string("accountKey")
        let account = try await MainActor.run { () throws -> (ASCCredentials, Int) in
            guard let credentials = appState.ascManager.credentials,
                  DashboardSummaryStore.accountKey(for: credentials) == accountKey else {
                throw ReleaseWorkflowError.accountChanged
            }
            return (credentials, appState.ascManager.credentialActivationRevision)
        }
        let api = ReleaseWorkflowASCAdapter(credentials: account.0, validateContext: { [appState] in
            try await MainActor.run {
                guard DashboardSummaryStore.accountKey(for: appState.ascManager.credentials) == accountKey,
                      appState.ascManager.credentialActivationRevision == account.1 else {
                    throw ReleaseWorkflowError.accountChanged
                }
            }
        })
        let service = ReleaseWorkflowService(directory: BlitzPaths.root.appendingPathComponent("release-operations"), api: api)
        let record: ReleaseWorkflowRecord
        if name == "release_prepare" {
            let target = ReleaseWorkflowTarget(projectID: try string("projectId"), projectPath: try string("projectPath"),
                appID: try string("appId"), bundleID: try string("bundleId"), platform: try string("platform"),
                accountKey: accountKey, versionID: try string("versionId"), buildID: try string("buildId"))
            guard let mode = ReleaseWorkflowMode(rawValue: try string("releaseMode")) else {
                throw MCPServerService.MCPError.invalidToolArgs
            }
            try await verifyRegisteredReleaseTarget(target)
            record = try await service.prepare(target: target, mode: mode)
        } else {
            let id = try string("operationId")
            let saved = try await service.loadRecord(operationID: id)
            guard saved.target.accountKey == accountKey else { throw ReleaseWorkflowError.accountChanged }
            try await verifyRegisteredReleaseTarget(saved.target)
            switch name {
            case "release_status": record = try await service.status(operationID: id, accountKey: accountKey)
            case "release_validate": record = try await service.validate(operationID: id, accountKey: accountKey)
            case "release_submit":
                guard arguments["confirm"] as? Bool == true else { throw ReleaseWorkflowError.confirmationRequired }
                record = try await service.submit(operationID: id, accountKey: accountKey,
                                                  confirmationDigest: try string("confirmationDigest"))
            default: throw MCPServerService.MCPError.invalidToolArgs
            }
        }
        return mcpJSON(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)))
    }

    private func verifyRegisteredReleaseTarget(_ target: ReleaseWorkflowTarget) async throws {
        try target.validate()
        let projects = await ProjectStorage().listProjects()
        guard let project = projects.first(where: { $0.id == target.projectID }),
              URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path == target.projectPath,
              project.metadata.bundleIdentifier == target.bundleID,
              project.platform.ascPlatformValue == target.platform else {
            throw ReleaseWorkflowError.identityChanged
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.projectPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReleaseWorkflowError.invalidTarget
        }
    }
}
