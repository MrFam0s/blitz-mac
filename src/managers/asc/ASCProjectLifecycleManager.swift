import Foundation
import AppKit

extension ASCManager {
    struct ProjectSnapshot {
        let projectId: String
        let accountKey: String?
        let resolvedFields: Set<String>
        let failedFields: Set<String>
        let cacheDate: Date?
        let bundleId: String?
        let app: ASCApp?
        let appStoreVersions: [ASCAppStoreVersion]
        let localizations: [ASCVersionLocalization]
        let appInfoLocalizationsByLocale: [String: ASCAppInfoLocalization]
        let screenshotSetsByLocale: [String: [ASCScreenshotSet]]
        let screenshotsByLocale: [String: [String: [ASCScreenshot]]]
        let customerReviews: [ASCCustomerReview]
        let builds: [ASCBuild]
        let betaGroups: [ASCBetaGroup]
        let betaLocalizations: [ASCBetaLocalization]
        let betaFeedback: [String: [ASCBetaFeedback]]
        let selectedBuildId: String?
        let inAppPurchases: [ASCInAppPurchase]
        let subscriptionGroups: [ASCSubscriptionGroup]
        let subscriptionsPerGroup: [String: [ASCSubscription]]
        let appPricePoints: [ASCPricePoint]
        let currentAppPricePointId: String?
        let scheduledAppPricePointId: String?
        let scheduledAppPriceEffectiveDate: String?
        let appInfo: ASCAppInfo?
        let appInfoLocalization: ASCAppInfoLocalization?
        let ageRatingDeclaration: ASCAgeRatingDeclaration?
        let reviewDetail: ASCReviewDetail?
        let selectedVersionId: String?
        let selectedVersionBuild: ASCBuild?
        let reviewSubmissions: [ASCReviewSubmission]
        let reviewSubmissionItemsBySubmissionId: [String: [ASCReviewSubmissionItem]]
        let latestSubmissionItems: [ASCReviewSubmissionItem]
        let submissionHistoryEvents: [ASCSubmissionHistoryEvent]
        let attachedSubmissionItemIDs: Set<String>
        let resolutionCenterThreads: [IrisResolutionCenterThread]
        let irisFeedbackCycles: [IrisFeedbackCycle]
        let trackSlots: [String: [TrackSlot?]]
        let savedTrackState: [String: [TrackSlot?]]
        let screenshotImageCache: [String: NSImage]
        let appIconStatus: String?
        let monetizationStatus: String?
        let loadedTabs: Set<AppTab>
        let tabLoadedAt: [AppTab: Date]
        let tabsNeedingRevalidation: Set<AppTab>
        let screenshotLoadedAt: [String: Date]
        let feedbackLoadedAt: [String: Date]
        let appInformationLocale: String?
        let screenshotsLocale: String?

        @MainActor
        init(manager: ASCManager, projectId: String) {
            self.projectId = projectId
            tabsNeedingRevalidation = manager.tabsNeedingRevalidation
            screenshotLoadedAt = manager.screenshotLoadedAt
            feedbackLoadedAt = manager.feedbackLoadedAt
            appInformationLocale = manager.selectedAppInformationLocale
            screenshotsLocale = manager.selectedScreenshotsLocale
            accountKey = DashboardSummaryStore.accountKey(for: manager.credentials)
            resolvedFields = manager.overviewResolvedFields
            failedFields = manager.overviewFailedFields
            cacheDate = manager.overviewCacheDate
            bundleId = Self.normalizedBundleId(manager.app?.bundleId)
            app = manager.app
            appStoreVersions = manager.appStoreVersions
            localizations = manager.localizations
            appInfoLocalizationsByLocale = manager.appInfoLocalizationsByLocale
            screenshotSetsByLocale = manager.screenshotSetsByLocale
            screenshotsByLocale = manager.screenshotsByLocale
            customerReviews = manager.customerReviews
            builds = manager.builds
            betaGroups = manager.betaGroups
            betaLocalizations = manager.betaLocalizations
            betaFeedback = manager.betaFeedback
            selectedBuildId = manager.selectedBuildId
            inAppPurchases = manager.inAppPurchases
            subscriptionGroups = manager.subscriptionGroups
            subscriptionsPerGroup = manager.subscriptionsPerGroup
            appPricePoints = manager.appPricePoints
            currentAppPricePointId = manager.currentAppPricePointId
            scheduledAppPricePointId = manager.scheduledAppPricePointId
            scheduledAppPriceEffectiveDate = manager.scheduledAppPriceEffectiveDate
            appInfo = manager.appInfo
            appInfoLocalization = manager.appInfoLocalization
            ageRatingDeclaration = manager.ageRatingDeclaration
            reviewDetail = manager.reviewDetail
            selectedVersionId = manager.selectedVersionId
            selectedVersionBuild = manager.selectedVersionBuild
            reviewSubmissions = manager.reviewSubmissions
            reviewSubmissionItemsBySubmissionId = manager.reviewSubmissionItemsBySubmissionId
            latestSubmissionItems = manager.latestSubmissionItems
            submissionHistoryEvents = manager.submissionHistoryEvents
            attachedSubmissionItemIDs = manager.attachedSubmissionItemIDs
            resolutionCenterThreads = manager.resolutionCenterThreads
            irisFeedbackCycles = manager.irisFeedbackCycles
            trackSlots = manager.trackSlots
            savedTrackState = manager.savedTrackState
            screenshotImageCache = manager.screenshotImageCache
            appIconStatus = manager.appIconStatus
            monetizationStatus = manager.monetizationStatus
            var cachedLoadedTabs = manager.loadedTabs.intersection(Self.cachedProjectTabs)
            if manager.isLoadingTab[.app] == true || !manager.overviewReadinessLoadingFields.isEmpty
                || !manager.overviewFailedFields.isEmpty {
                cachedLoadedTabs.remove(.app)
            }
            loadedTabs = cachedLoadedTabs
            tabLoadedAt = manager.tabLoadedAt.filter { cachedLoadedTabs.contains($0.key) }
        }

        @MainActor
        func apply(to manager: ASCManager) {
            manager.tabsNeedingRevalidation = tabsNeedingRevalidation
            manager.screenshotLoadedAt = screenshotLoadedAt
            manager.feedbackLoadedAt = feedbackLoadedAt
            manager.selectedAppInformationLocale = appInformationLocale
            manager.selectedScreenshotsLocale = screenshotsLocale
            manager.app = app
            manager.appStoreVersions = appStoreVersions
            manager.localizations = localizations
            manager.appInfoLocalizationsByLocale = appInfoLocalizationsByLocale
            manager.screenshotSetsByLocale = screenshotSetsByLocale
            manager.screenshotsByLocale = screenshotsByLocale
            manager.customerReviews = customerReviews
            manager.builds = builds
            manager.betaGroups = betaGroups
            manager.betaLocalizations = betaLocalizations
            manager.betaFeedback = betaFeedback
            manager.selectedBuildId = selectedBuildId
            manager.inAppPurchases = inAppPurchases
            manager.subscriptionGroups = subscriptionGroups
            manager.subscriptionsPerGroup = subscriptionsPerGroup
            manager.appPricePoints = appPricePoints
            manager.currentAppPricePointId = currentAppPricePointId
            manager.scheduledAppPricePointId = scheduledAppPricePointId
            manager.scheduledAppPriceEffectiveDate = scheduledAppPriceEffectiveDate
            manager.appInfo = appInfo
            manager.appInfoLocalization = appInfoLocalization
            manager.ageRatingDeclaration = ageRatingDeclaration
            manager.reviewDetail = reviewDetail
            manager.selectedVersionId = selectedVersionId
            manager.selectedVersionBuild = selectedVersionBuild
            manager.reviewSubmissions = reviewSubmissions
            manager.reviewSubmissionItemsBySubmissionId = reviewSubmissionItemsBySubmissionId
            manager.latestSubmissionItems = latestSubmissionItems
            manager.submissionHistoryEvents = submissionHistoryEvents
            manager.attachedSubmissionItemIDs = attachedSubmissionItemIDs
            manager.resolutionCenterThreads = resolutionCenterThreads
            manager.irisFeedbackCycles = irisFeedbackCycles
            manager.trackSlots = trackSlots
            manager.savedTrackState = savedTrackState
            manager.screenshotImageCache = screenshotImageCache
            manager.appIconStatus = appIconStatus
            manager.monetizationStatus = monetizationStatus
            manager.loadedTabs = loadedTabs
            manager.tabLoadedAt = tabLoadedAt
            manager.loadedProjectId = projectId
            manager.tabError = [:]
            manager.isLoadingTab = [:]
            manager.isLoadingApp = false
            manager.isLoadingIrisFeedback = false
            manager.loadingFeedbackBuildIds = []
            manager.irisFeedbackError = nil
            manager.writeError = nil
            manager.submissionError = nil
            manager.overviewResolvedFields = resolvedFields
            manager.overviewFailedFields = failedFields
            manager.overviewCacheDate = cacheDate
            manager.overviewReadinessLoadingFields = loadedTabs.contains(.app)
                ? [] : ASCManager.overviewAllFields.subtracting(resolvedFields)
        }

        func matches(bundleId: String?) -> Bool {
            let requestedBundleId = Self.normalizedBundleId(bundleId)
            guard let requestedBundleId else { return true }
            guard let snapshotBundleId = self.bundleId else { return false }
            return snapshotBundleId == requestedBundleId
        }

        private static func normalizedBundleId(_ bundleId: String?) -> String? {
            let trimmed = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed
        }

        private static let cachedProjectTabs: Set<AppTab> = [
            .app,
            .appInformation,
            .screenshots,
            .monetization,
            .review,
            .analytics,
            .reviews,
            .builds,
            .groups,
            .betaInfo,
            .feedback,
        ]
    }

    private static let projectCacheFreshness: TimeInterval = 120

    func checkAppIcon(projectId: String) {
        iconCheckedAt = nil
        ProjectAppIconLoader.invalidate(for: projectId)
        refreshAppIconStatusIfNeeded(for: projectId)
    }

    func prepareForProjectSwitch(to projectId: String, bundleId: String?) {
        if loadedProjectId == projectId,
           app?.bundleId == bundleId, app != nil { return }
        cacheCurrentProjectSnapshot()
        resetProjectData(preserveCredentials: true)

        if let snapshot = projectSnapshots[projectId], snapshot.matches(bundleId: bundleId),
           snapshot.accountKey == DashboardSummaryStore.accountKey(for: credentials) {
            snapshot.apply(to: self)
        } else {
            loadedProjectId = projectId
            overviewReadinessLoadingFields = Self.overviewAllFields
            Task {
                await ASCUpdateLogger.shared.event("project_switch_reset", metadata: [
                    "bundleId": bundleId ?? "nil",
                    "projectId": projectId,
                    "reason": projectSnapshots[projectId] == nil ? "no_snapshot" : "bundle_mismatch",
                ])
            }
        }
    }

    func loadStoredCredentialsIfNeeded() {
        guard credentials == nil || service == nil else { return }
        let creds = ASCCredentials.load()
        try? ASCAuthBridge().syncCredentials(creds)
        Self.syncWebSessionFileFromKeychain()
        credentials = creds
        service = creds.map { AppStoreConnectService(credentials: $0) }
    }

    func loadCredentials(for projectId: String, bundleId: String?) async {
        let bundle = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if loadedProjectId != projectId {
            prepareForProjectSwitch(to: projectId, bundleId: bundle)
        }
        loadStoredCredentialsIfNeeded()
        guard !restoringCache else { return }
        if let bundle, app != nil, app?.bundleId != bundle {
            resetProjectData(preserveCredentials: true)
            loadedProjectId = projectId
        }
        let revision = projectRevision
        credentialsError = nil
        if app == nil, let bundle, !bundle.isEmpty,
           let account = DashboardSummaryStore.accountKey(for: credentials) {
            restoringCache = true
            isLoadingApp = true
            let saved = await overviewCache.load(account: account, bundle: bundle)
            guard projectRevision == revision else { return }
            restoringCache = false
            isLoadingApp = false
            guard !Task.isCancelled else { return }
            if let saved { saved.apply(to: self) }
            isLoadingApp = false
        }
        refreshAppIconStatusIfNeeded(for: projectId)
        if let bundle, !bundle.isEmpty, credentials != nil, app?.bundleId != bundle {
            await fetchApp(bundleId: bundle)
        }
    }

    func clearForProjectSwitch() {
        resetProjectData(preserveCredentials: false)
    }

    func saveCredentials(_ creds: ASCCredentials, projectId: String, bundleId: String?) async throws {
        try creds.save()
        resetProjectData(preserveCredentials: false)
        loadedProjectId = projectId
        credentials = creds
        service = AppStoreConnectService(credentials: creds)
        credentialsError = nil
        cancelBackgroundHydrationTasks()
        loadedTabs = []
        tabLoadedAt = [:]
        tabError = [:]
        isLoadingTab = [:]
        loadingFeedbackBuildIds = []

        if let bundleId, !bundleId.isEmpty {
            await fetchApp(bundleId: bundleId)
        }

        credentialActivationRevision += 1
    }

    func deleteCredentials() {
        ASCCredentials.delete()
        let projectId = loadedProjectId
        clearForProjectSwitch()
        loadedProjectId = projectId
    }

    func refreshAppIconStatusIfNeeded(for projectId: String?) {
        guard let projectId, !projectId.isEmpty else { return }
        if projectId.hasPrefix("asc:") {
            overviewReadinessLoadingFields.remove("App Icon")
            return
        }
        guard iconCheckTask == nil else { return }
        if let iconCheckedAt, Date().timeIntervalSince(iconCheckedAt) < 120 { return }
        let revision = projectRevision
        overviewReadinessLoadingFields.insert("App Icon")
        let path = BlitzPaths.projects.appendingPathComponent(projectId).path
        iconCheckTask = Task { [weak self] in
            let status = await ProjectAppIconLoader.loadStatus(for: projectId, projectPath: path)
            guard let self, self.projectRevision == revision, !Task.isCancelled else { return }
            self.appIconStatus = status
            self.iconCheckedAt = Date()
            self.iconCheckTask = nil
            self.finishOverviewReadinessLoading(["App Icon"])
        }
    }

    func cancelBackgroundHydration(for tab: AppTab) {
        tabHydrationTasks[tab]?.cancel()
        tabHydrationTasks.removeValue(forKey: tab)
    }

    func cancelBackgroundHydrationTasks() {
        for task in tabHydrationTasks.values {
            task.cancel()
        }
        tabHydrationTasks.removeAll()
    }

    func startBackgroundHydration(for tab: AppTab, operation: @escaping @MainActor () async -> Void) {
        cancelBackgroundHydration(for: tab)
        tabHydrationTasks[tab] = Task {
            await operation()
        }
    }

    func waitForBackgroundHydration(for tab: AppTab) async {
        if let task = tabHydrationTasks[tab] {
            await task.value
        }
    }

    func resetProjectData(preserveCredentials: Bool) {
        projectRevision = UUID()
        resetTabCacheTasks()
        for task in tabLoadTasks.values { task.cancel() }
        tabLoadTasks.removeAll()
        restoringCache = false
        iconCheckTask?.cancel()
        iconCheckTask = nil
        iconCheckedAt = nil
        cancelBackgroundHydrationTasks()
        overviewReadinessLoadingFields = []
        overviewResolvedFields = []
        overviewFailedFields = []
        overviewCacheDate = nil
        loadingFeedbackBuildIds = []

        if !preserveCredentials {
            projectSnapshots.removeAll()
            credentials = nil
            service = nil
        }

        app = nil
        isLoadingCredentials = false
        credentialsError = nil
        isLoadingApp = false
        appStoreVersions = []
        localizations = []
        selectedAppInformationLocale = nil
        appInfoLocalizationsByLocale = [:]
        screenshotSetsByLocale = [:]
        screenshotsByLocale = [:]
        selectedScreenshotsLocale = nil
        customerReviews = []
        builds = []
        betaGroups = []
        betaLocalizations = []
        betaFeedback = [:]
        selectedBuildId = nil
        inAppPurchases = []
        subscriptionGroups = []
        subscriptionsPerGroup = [:]
        appPricePoints = []
        currentAppPricePointId = nil
        scheduledAppPricePointId = nil
        scheduledAppPriceEffectiveDate = nil
        appInfo = nil
        appInfoLocalization = nil
        ageRatingDeclaration = nil
        reviewDetail = nil
        selectedVersionId = nil
        selectedVersionBuild = nil
        pendingFormValues = [:]
        showSubmitPreview = false
        showVersionDraftSheet = false
        showReleaseAutomationSheet = false
        isSubmitting = false
        isCreatingVersion = false
        versionCreationOperation = nil
        submissionError = nil
        versionCreationError = nil
        writeError = nil
        reviewSubmissions = []
        reviewSubmissionItemsBySubmissionId = [:]
        latestSubmissionItems = []
        submissionHistoryEvents = []
        appIconStatus = nil
        monetizationStatus = nil
        attachedSubmissionItemIDs = []
        trackSlots = [:]
        savedTrackState = [:]
        screenshotImageCache = [:]
        isLoadingTab = [:]
        tabError = [:]
        loadedTabs = []
        tabLoadedAt = [:]
        pendingBundleIDSetup = nil
        if !preserveCredentials {
            loadedProjectId = nil
        }

        resolutionCenterThreads = []
        irisFeedbackCycles = []
        isLoadingIrisFeedback = false
        irisFeedbackError = nil
        cancelPendingWebAuth()
    }

    func cacheCurrentProjectSnapshot() {
        guard let projectId = loadedProjectId else { return }
        guard app != nil || !loadedTabs.isEmpty else { return }
        // Bound retained screenshot thumbnails and metadata to recently opened projects.
        if projectSnapshots.count >= 12, projectSnapshots[projectId] == nil,
           let oldest = projectSnapshots.min(by: {
               ($0.value.tabLoadedAt.values.max() ?? .distantPast) < ($1.value.tabLoadedAt.values.max() ?? .distantPast)
           })?.key { projectSnapshots.removeValue(forKey: oldest) }
        projectSnapshots[projectId] = ProjectSnapshot(manager: self, projectId: projectId)
    }

    func shouldRefreshTabCache(_ tab: AppTab) -> Bool {
        guard loadedTabs.contains(tab) else { return true }
        guard let loadedAt = tabLoadedAt[tab] else { return true }
        return tabsNeedingRevalidation.contains(tab) || tabError[tab] != nil
            || !overviewFailedFields.isEmpty && tab == .app
            || Date().timeIntervalSince(loadedAt) > Self.projectCacheFreshness
    }
}
