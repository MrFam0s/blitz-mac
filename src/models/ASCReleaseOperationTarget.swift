import Foundation

/// Immutable UI/account identity for asynchronous release operations.
struct ASCReleaseOperationTarget: Equatable {
    let revision: UUID
    let projectId: String?
    let appId: String
    let bundleId: String
    let accountKey: String?
    let credentialRevision: Int
    let versionId: String?
    let platform: ProjectPlatform?

    @MainActor func matches(_ manager: ASCManager) -> Bool {
        manager.projectRevision == revision && manager.loadedProjectId == projectId
            && manager.app?.id == appId && manager.app?.bundleId == bundleId && (platform == nil || manager.releasePlatform == platform)
            && DashboardSummaryStore.accountKey(for: manager.credentials) == accountKey
            && manager.credentialActivationRevision == credentialRevision
            && (versionId == nil || manager.selectedVersion?.id == versionId)
    }
    @MainActor func check(_ manager: ASCManager) throws {
        guard !Task.isCancelled, matches(manager) else { throw CancellationError() }
    }
}

extension SubmissionReadiness {
    /// Selecting a verified build satisfies only the build row; every other
    /// required field must still have a freshly checked value.
    func isComplete(selectingBuild build: ASCBuild?) -> Bool {
        fields.filter(\.required).allSatisfy { field in
            if field.label == "Build", build != nil { return true }
            return !field.isLoading && !field.loadFailed && !(field.value ?? "").isEmpty
        }
    }
}
