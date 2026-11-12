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
        func service(for target: ReleaseWorkflowTarget? = nil) -> ReleaseWorkflowService {
            let api = ReleaseWorkflowASCAdapter(credentials: account.0, validateContext: { [appState] in
                try await MainActor.run {
                    guard DashboardSummaryStore.accountKey(for: appState.ascManager.credentials) == accountKey,
                          appState.ascManager.credentialActivationRevision == account.1 else {
                        throw ReleaseWorkflowError.accountChanged
                    }
                }
                if let target { try await Self.verifyRegisteredReleaseTarget(target) }
            })
            return ReleaseWorkflowService(directory: BlitzPaths.root.appendingPathComponent("release-operations"), api: api)
        }
        let record: ReleaseWorkflowRecord
        if name == "release_prepare" {
            let projectID = try string("projectId")
            let project = try await Self.registeredReleaseProject(projectID)
            let appID = try string("appId"), bundleID = try string("bundleId"), platform = try string("platform")
            let requestedTargetID = try arguments.keys.contains("releaseTargetId") ? string("releaseTargetId") : nil
            let configured = try RegisteredReleaseTarget.resolve(project: project, releaseTargetID: requestedTargetID,
                appID: appID, bundleID: bundleID, platform: platform, accountKey: accountKey)
            let target = ReleaseWorkflowTarget(projectID: projectID, projectPath: try string("projectPath"),
                appID: appID, bundleID: bundleID, platform: platform,
                accountKey: accountKey, versionID: try string("versionId"), buildID: try string("buildId"),
                releaseTargetID: configured.id)
            guard let mode = ReleaseWorkflowMode(rawValue: try string("releaseMode")) else {
                throw MCPServerService.MCPError.invalidToolArgs
            }
            try await Self.verifyRegisteredReleaseTarget(target)
            record = try await service(for: target).prepare(target: target, mode: mode)
        } else {
            let id = try string("operationId")
            let saved = try await service().loadRecord(operationID: id)
            guard saved.target.accountKey == accountKey else { throw ReleaseWorkflowError.accountChanged }
            // Later commands derive the identity only from the immutable record.
            // An optional explicit ID can assert it, never retarget the operation.
            if arguments.keys.contains("releaseTargetId") {
                guard try string("releaseTargetId") == saved.target.releaseTargetID else { throw ReleaseWorkflowError.identityChanged }
            }
            try await Self.verifyRegisteredReleaseTarget(saved.target)
            let service = service(for: saved.target)
            switch name {
            case "release_status": record = try await service.status(operationID: id, accountKey: accountKey)
            case "release_validate": record = try await service.validate(operationID: id, accountKey: accountKey)
            case "release_submit":
                guard arguments["confirm"] as? Bool == true else { throw ReleaseWorkflowError.confirmationRequired }
                record = try await service.submit(operationID: id, accountKey: accountKey,
                    confirmationDigest: try string("confirmationDigest"),
                    resumeSubmissionID: try arguments.keys.contains("resumeSubmissionId") ? string("resumeSubmissionId") : nil,
                    confirmLegacyDraftRecovery: arguments["confirmLegacyDraftRecovery"] as? Bool ?? false)
            default: throw MCPServerService.MCPError.invalidToolArgs
            }
        }
        return mcpJSON(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)))
    }

    func executeGetReleaseTargets(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let projectID = arguments["projectId"] as? String, !projectID.isEmpty else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let project = try await Self.registeredReleaseProject(projectID)
        let targets: [[String: Any]] = project.metadata.resolvedReleaseTargets.map { target in
            var value: [String: Any] = ["releaseTargetId": target.id, "name": target.displayName,
                "platform": target.platform.ascPlatformValue, "bundleId": target.bundleIdentifier.map { $0 as Any } ?? NSNull()]
            if let binding = target.storeBinding {
                value["storeBinding"] = ["appId": binding.appId, "accountKey": binding.accountKey,
                    "bundleId": binding.bundleIdentifier, "sku": binding.sku.map { $0 as Any } ?? NSNull()]
            } else { value["storeBinding"] = NSNull() }
            return value
        }
        return mcpJSON(["projectId": project.id,
            "projectPath": URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path,
            "releaseTargets": targets, "requiresReleaseTargetId": targets.count != 1,
            "note": "Local configured targets only. Select exactly one intended target; this does not verify Apple readiness or authorize creation/submission."])
    }

    private static func registeredReleaseProject(_ projectID: String) async throws -> Project {
        let projects = await ProjectStorage().listProjects()
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw ReleaseWorkflowError.identityChanged
        }
        return project
    }

    private static func verifyRegisteredReleaseTarget(_ target: ReleaseWorkflowTarget) async throws {
        let project = try await registeredReleaseProject(target.projectID)
        try RegisteredReleaseTarget.verify(target, project: project)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.projectPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReleaseWorkflowError.invalidTarget
        }
    }
}
