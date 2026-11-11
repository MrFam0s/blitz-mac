import Foundation

/// Resolve the caller's named project target, never the current UI selection.
enum RegisteredReleaseTarget {
    static func resolve(project: Project, releaseTargetID: String?, appID: String,
                        bundleID: String, platform: String, accountKey: String) throws -> ProjectReleaseTarget {
        let configured = project.metadata.resolvedReleaseTargets
        guard Set(configured.map(\.id)).count == configured.count,
              configured.allSatisfy({ ReleaseWorkflowTarget.validID($0.id) }) else {
            throw ProjectReleaseTargetError.invalid
        }
        let target = try project.metadata.resolveReleaseTarget(id: releaseTargetID)
        guard target.bundleIdentifier == bundleID, target.platform.ascPlatformValue == platform else {
            throw ReleaseWorkflowError.identityChanged
        }
        if let binding = target.storeBinding {
            guard binding.appId == appID, binding.accountKey == accountKey,
                  binding.bundleIdentifier == bundleID else { throw ReleaseWorkflowError.identityChanged }
        } else {
            // Older metadata had no persisted Store binding. Preserve that one
            // legacy target; the live adapter still verifies app/account/build.
            guard target.id == "legacy", configured.count == 1 else {
                throw NSError(domain: "BlitzReleaseTarget", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Das Veröffentlichungsziel ist noch keinem bestätigten App-Store-Datensatz zugeordnet. Verknüpfe zuerst genau dieses Ziel in Blitz Neo."])
            }
        }
        return target
    }

    static func verify(_ target: ReleaseWorkflowTarget, project: Project) throws {
        try target.validate()
        guard project.id == target.projectID,
              URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path == target.projectPath else {
            throw ReleaseWorkflowError.identityChanged
        }
        _ = try resolve(project: project, releaseTargetID: target.releaseTargetID, appID: target.appID,
                        bundleID: target.bundleID, platform: target.platform, accountKey: target.accountKey)
    }
}
