import Foundation

protocol ASCOverviewService {
    func fetchApp(id: String) async throws -> ASCApp
    func fetchBuilds(appId: String) async throws -> [ASCBuild]
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion]
    func fetchLocalizations(versionId: String) async throws -> [ASCVersionLocalization]
    func fetchAppInfo(appId: String) async throws -> ASCAppInfo
    func fetchAppInfoLocalizations(appInfoId: String) async throws -> [ASCAppInfoLocalization]
    func fetchAgeRating(appInfoId: String) async throws -> ASCAgeRatingDeclaration
    func fetchReviewDetail(versionId: String) async throws -> ASCReviewDetail
    func fetchBuildAttachedToVersion(versionId: String) async throws -> ASCBuild?
    func fetchScreenshotSets(localizationId: String) async throws -> [ASCScreenshotSet]
    func fetchScreenshots(setId: String) async throws -> [ASCScreenshot]
    func fetchPricingConfiguredDetailed(appId: String) async throws -> Bool
}

extension AppStoreConnectService: ASCOverviewService {}

extension ASCManager {
    /// Independent sections publish as they arrive. A failed section retains its
    /// last value and never turns an unknown server response into a missing field.
    @discardableResult
    func overviewRequest<T>(
        fields: Set<String>, revision: UUID,
        operation: @MainActor () async throws -> T, apply: @MainActor (T) -> Void
    ) async -> Bool {
        do {
            let value = try await operation()
            guard projectRevision == revision, !Task.isCancelled else { return false }
            apply(value)
            finishOverviewReadinessLoading(fields)
            return true
        } catch {
            guard projectRevision == revision, !Task.isCancelled else { return false }
            overviewReadinessLoadingFields.subtract(fields)
            overviewFailedFields.formUnion(fields)
            return false
        }
    }

    func loadOverview(using service: any ASCOverviewService) async {
        guard let appId = app?.id else { return }
        let revision = projectRevision
        overviewFailedFields = []
        startOverviewReadinessLoading(Self.overviewAllFields.subtracting(["App Icon"]))
        refreshAppIconStatusIfNeeded(for: loadedProjectId)
        async let identity: Bool = overviewRequest(fields: ["Content Rights"], revision: revision,
            operation: { try await service.fetchApp(id: appId) }, apply: { app = $0 })
        async let version: Void = loadOverviewVersion(using: service, appId: appId, revision: revision)
        async let info: Void = loadOverviewInfo(using: service, appId: appId, revision: revision)
        async let pricing: Bool = overviewRequest(fields: ["Pricing"], revision: revision,
            operation: { try await service.fetchPricingConfiguredDetailed(appId: appId) },
            apply: { monetizationStatus = $0 ? "Configured" : nil })
        async let buildInventory: Bool = overviewRequest(fields: [], revision: revision,
            operation: { try await service.fetchBuilds(appId: appId) }, apply: { builds = $0 })
        _ = await (identity, version, info, pricing, buildInventory)
        guard projectRevision == revision, !Task.isCancelled else { return }
        if overviewFailedFields.isEmpty {
            overviewCacheDate = Date()
            if let account = DashboardSummaryStore.accountKey(for: credentials), app != nil {
                let entry = ASCOverviewCacheEntry(manager: self, savedAt: overviewCacheDate!)
                await overviewCache.save(entry, account: account)
            }
        }
    }

    private func loadOverviewVersion(using service: any ASCOverviewService, appId: String, revision: UUID) async {
        let dependentFields = Self.overviewVersionFieldLabels.union(Self.overviewLocalizationFieldLabels)
            .union(Self.overviewReviewFieldLabels).union(Self.overviewBuildFieldLabels)
            .union(Self.overviewScreenshotFieldLabels)
        let success = await overviewRequest(fields: Self.overviewVersionFieldLabels, revision: revision,
            operation: { try await service.fetchAppStoreVersions(appId: appId) }, apply: { versions in
                let previous = selectedVersionId
                appStoreVersions = versions
                syncSelectedVersion()
                if previous != selectedVersionId {
                    // A refreshed default version must not borrow the previous version's text.
                    localizations = []
                    reviewDetail = nil
                    selectedVersionBuild = nil
                    screenshotSetsByLocale = [:]
                    screenshotsByLocale = [:]
                    overviewResolvedFields.subtract(dependentFields.subtracting(Self.overviewVersionFieldLabels))
                }
            })
        guard projectRevision == revision, !Task.isCancelled else { return }
        guard success else {
            overviewReadinessLoadingFields.subtract(dependentFields)
            overviewFailedFields.formUnion(dependentFields)
            return
        }
        guard let versionId = selectedVersion?.id else {
            localizations = []
            selectedVersionBuild = nil
            reviewDetail = nil
            screenshotSetsByLocale = [:]
            screenshotsByLocale = [:]
            finishOverviewReadinessLoading(dependentFields)
            return
        }
        async let texts: Void = loadOverviewTexts(using: service, versionId: versionId, revision: revision)
        async let review: Bool = overviewRequest(fields: Self.overviewReviewFieldLabels, revision: revision,
            operation: { () async throws -> ASCReviewDetail? in
                do { return try await service.fetchReviewDetail(versionId: versionId) }
                catch ASCError.notFound { return nil }
            }, apply: { reviewDetail = $0 })
        async let build: Bool = overviewRequest(fields: Self.overviewBuildFieldLabels, revision: revision,
            operation: { try await service.fetchBuildAttachedToVersion(versionId: versionId) },
            apply: { selectedVersionBuild = $0 })
        _ = await (texts, review, build)
    }

    private func loadOverviewTexts(using service: any ASCOverviewService, versionId: String, revision: UUID) async {
        let success = await overviewRequest(fields: Self.overviewLocalizationFieldLabels, revision: revision,
            operation: { try await service.fetchLocalizations(versionId: versionId) }, apply: { localizations = $0 })
        guard projectRevision == revision, !Task.isCancelled else { return }
        guard success else {
            overviewReadinessLoadingFields.subtract(Self.overviewScreenshotFieldLabels)
            overviewFailedFields.formUnion(Self.overviewScreenshotFieldLabels)
            return
        }
        guard let localization = primaryVersionLocalization() else {
            screenshotSetsByLocale = [:]
            screenshotsByLocale = [:]
            finishOverviewReadinessLoading(Self.overviewScreenshotFieldLabels)
            return
        }
        _ = await overviewRequest(fields: Self.overviewScreenshotFieldLabels, revision: revision,
            operation: {
                let sets = try await service.fetchScreenshotSets(localizationId: localization.id)
                var screenshots: [String: [ASCScreenshot]] = [:]
                for set in sets {
                    try Task.checkCancellation()
                    screenshots[set.id] = try await service.fetchScreenshots(setId: set.id)
                }
                return (sets, screenshots)
            }, apply: { sets, screenshots in
                updateScreenshotCache(locale: localization.attributes.locale, sets: sets, screenshots: screenshots)
            })
    }

    private func loadOverviewInfo(using service: any ASCOverviewService, appId: String, revision: UUID) async {
        let success = await overviewRequest(fields: Self.overviewAppInfoFieldLabels, revision: revision,
            operation: { try await service.fetchAppInfo(appId: appId) }, apply: { appInfo = $0 })
        guard projectRevision == revision, !Task.isCancelled else { return }
        guard success, let infoId = appInfo?.id else {
            overviewReadinessLoadingFields.subtract(Self.overviewMetadataFieldLabels)
            overviewFailedFields.formUnion(Self.overviewMetadataFieldLabels)
            return
        }
        async let texts: Bool = overviewRequest(fields: ["App Name", "Privacy Policy URL"], revision: revision,
            operation: { try await service.fetchAppInfoLocalizations(appInfoId: infoId) }, apply: { values in
                appInfoLocalizationsByLocale = Dictionary(values.map { ($0.attributes.locale, $0) }, uniquingKeysWith: { _, new in new })
                appInfoLocalization = primaryAppInfoLocalization(in: values)
            })
        async let age: Bool = overviewRequest(fields: ["Age Rating"], revision: revision,
            operation: { try await service.fetchAgeRating(appInfoId: infoId) }, apply: { ageRatingDeclaration = $0 })
        _ = await (texts, age)
    }

    func loadOverviewProducts(service: AppStoreConnectService, appId: String, revision: UUID) async {
        let fields: Set<String> = ["In-App Purchases & Subscriptions"]
        let approved: Set<String> = ["READY_FOR_SALE", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE",
                                     "REPLACED_WITH_NEW_VERSION", "PROCESSING_FOR_APP_STORE"]
        guard projectRevision == revision, !Task.isCancelled else { return }
        guard !appStoreVersions.contains(where: { approved.contains($0.attributes.appStoreState ?? "") }) else {
            finishOverviewReadinessLoading(fields)
            return
        }
        let success = await overviewRequest(fields: fields, revision: revision, operation: {
            async let iaps = service.fetchInAppPurchases(appId: appId)
            async let groups = service.fetchSubscriptionGroups(appId: appId)
            let fetchedGroups = try await groups
            var subscriptions: [String: [ASCSubscription]] = [:]
            for group in fetchedGroups {
                try Task.checkCancellation()
                subscriptions[group.id] = try await service.fetchSubscriptionsInGroup(groupId: group.id)
            }
            return (try await iaps, fetchedGroups, subscriptions)
        }, apply: { iaps, groups, subscriptions in
            inAppPurchases = iaps
            subscriptionGroups = groups
            subscriptionsPerGroup = subscriptions
        })
        if success, projectRevision == revision, !Task.isCancelled {
            await refreshAttachedSubmissionItemIDs()
        }
    }
}
