import Foundation

protocol ASCReviewMetadataService {
    func fetchReviewDetail(versionId: String) async throws -> ASCReviewDetail
    func fetchAgeRating(appInfoId: String) async throws -> ASCAgeRatingDeclaration
}

protocol ASCReviewSubmissionDataService {
    func fetchReviewSubmissions(appId: String) async throws -> [ASCReviewSubmission]
    func fetchReviewSubmissionItems(submissionId: String) async throws -> [ASCReviewSubmissionItem]
}

protocol ASCReviewDataService: ASCReviewMetadataService, ASCReviewSubmissionDataService, ASCVersionBuildService {
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion]
    func fetchAppInfo(appId: String) async throws -> ASCAppInfo
    func fetchBuilds(appId: String) async throws -> [ASCBuild]
}

extension AppStoreConnectService: ASCReviewDataService {}

/// Captured before any request. A project reopened with the same IDs is still a
/// different load, and changing the selected version invalidates its review data.
@MainActor
private struct ASCReviewDataTarget {
    let projectID: String?
    let projectRevision: UUID
    let appID: String?
    let bundleID: String?
    let accountKey: String?
    let credentialRevision: Int
    let configuredPlatform: ProjectPlatform?
    let selectedVersionID: String?
    let resolvedVersionID: String?

    init(_ manager: ASCManager) {
        projectID = manager.loadedProjectId
        projectRevision = manager.projectRevision
        appID = manager.app?.id
        bundleID = manager.app?.bundleId
        accountKey = DashboardSummaryStore.accountKey(for: manager.credentials)
        credentialRevision = manager.credentialActivationRevision
        configuredPlatform = manager.configuredReleasePlatform
        selectedVersionID = manager.selectedVersionId
        resolvedVersionID = manager.selectedVersion?.id
    }

    func matches(_ manager: ASCManager) -> Bool {
        !Task.isCancelled
            && manager.loadedProjectId == projectID
            && manager.projectRevision == projectRevision
            && manager.app?.id == appID && manager.app?.bundleId == bundleID
            && DashboardSummaryStore.accountKey(for: manager.credentials) == accountKey
            && manager.credentialActivationRevision == credentialRevision
            && manager.configuredReleasePlatform == configuredPlatform
            && manager.selectedVersionId == selectedVersionID
            && manager.selectedVersion?.id == resolvedVersionID
    }
}

extension ASCManager {
    func loadReviewTab(using service: any ASCReviewDataService) async throws {
        let target = ASCReviewDataTarget(self)
        guard let appID = target.appID, target.matches(self) else { throw CancellationError() }

        async let versionsTask = service.fetchAppStoreVersions(appId: appID)
        async let appInfoTask: ASCAppInfo? = try? await service.fetchAppInfo(appId: appID)
        async let buildsTask = service.fetchBuilds(appId: appID)

        let versions = try await versionsTask
        guard target.matches(self) else { throw CancellationError() }
        // Resolve against the incoming versions without publishing them early.
        // This preserves the normal initial/default selection and platform filter.
        let platform = target.configuredPlatform ?? ASCReleaseStatus.inferredPlatform(from: versions)
        let scopedVersions = platform != nil || target.projectID == nil
            ? ASCReleaseStatus.versions(versions, for: platform) : []
        let selected = scopedVersions.first { $0.id == target.selectedVersionID }
            ?? ASCReleaseStatus.defaultSelectedVersion(for: scopedVersions)

        let detail: ASCReviewDetail?
        let attachedBuild: ASCBuild?
        if let versionID = selected?.id {
            detail = await fetchReviewDetailLogged(service: service, versionId: versionID, context: "review_tab_load")
            guard target.matches(self) else { throw CancellationError() }
            attachedBuild = try? await service.fetchBuildAttachedToVersion(versionId: versionID)
        } else {
            detail = nil
            attachedBuild = nil
        }
        guard target.matches(self) else { throw CancellationError() }
        let fetchedAppInfo = await appInfoTask
        let fetchedBuilds = try await buildsTask
        guard target.matches(self) else { throw CancellationError() }

        appStoreVersions = versions
        selectedVersionId = selected?.id
        reviewDetail = detail
        selectedVersionBuild = attachedBuild
        appInfo = fetchedAppInfo
        builds = fetchedBuilds

        // The primary commit may initialize the default version. Capture that
        // selection synchronously, while retaining the same validated identity.
        let secondaryTarget = ASCReviewDataTarget(self)
        startBackgroundHydration(for: .review) {
            await self.hydrateReviewSecondaryData(
                target: secondaryTarget, appInfoID: fetchedAppInfo?.id, service: service
            )
        }
    }

    private func hydrateReviewSecondaryData(
        target: ASCReviewDataTarget,
        appInfoID: String?,
        service: any ASCReviewDataService
    ) async {
        guard let appID = target.appID, target.matches(self) else { return }
        let fetchedAgeRating: ASCAgeRatingDeclaration?
        if let appInfoID {
            fetchedAgeRating = await fetchAgeRatingLogged(
                service: service, appInfoId: appInfoID, context: "review_secondary"
            )
        } else {
            fetchedAgeRating = nil
        }
        guard target.matches(self) else { return }
        ageRatingDeclaration = fetchedAgeRating
        await refreshReviewSubmissionData(appId: appID, service: service, isCurrent: { target.matches(self) })
        guard target.matches(self) else { return }
        rebuildSubmissionHistory(appId: appID)
        refreshSubmissionFeedbackIfNeeded()
    }
}
