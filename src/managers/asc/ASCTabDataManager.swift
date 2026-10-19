import Foundation

extension ASCManager {
    func ensureTabData(_ tab: AppTab) async {
        guard credentials != nil, !restoringCache else { return }

        if loadedTabs.contains(tab) {
            if shouldRefreshTabCache(tab) {
                await refreshTabData(tab)
            }
            return
        }

        await fetchTabData(tab)
    }

    func hasLoadedTabData(_ tab: AppTab) -> Bool {
        loadedTabs.contains(tab)
    }

    func isTabLoading(_ tab: AppTab) -> Bool {
        isLoadingTab[tab] == true || isLoadingApp
    }

    func isFeedbackLoading(for buildId: String?) -> Bool {
        guard let buildId, !buildId.isEmpty else {
            return isLoadingTab[.feedback] == true
        }
        return loadingFeedbackBuildIds.contains(buildId)
    }

    @discardableResult
    func fetchApp(bundleId: String, exactName: String? = nil) async -> Bool {
        guard let service else { return false }
        isLoadingApp = true
        let revision = projectRevision
        defer { if projectRevision == revision { isLoadingApp = false } }
        do {
            let fetched = try await service.fetchApp(bundleId: bundleId, exactName: exactName)
            guard projectRevision == revision, !Task.isCancelled else { return false }
            app = fetched
            credentialsError = nil
            isLoadingApp = false
            return true
        } catch {
            guard projectRevision == revision, !Task.isCancelled else { return false }
            app = nil
            credentialsError = error.localizedDescription
            isLoadingApp = false
            return false
        }
    }

    func fetchTabData(_ tab: AppTab) async {
        if let task = tabLoadTasks[tab] { await task.value; return }
        guard !loadedTabs.contains(tab) else { return }
        await refreshTabData(tab)
    }

    /// Called after bundle ID setup completes and the app is confirmed in ASC.
    func resetTabState() {
        projectRevision = UUID()
        cancelBackgroundHydrationTasks()
        for task in tabLoadTasks.values { task.cancel() }
        tabLoadTasks.removeAll()
        tabError.removeAll()
        loadedTabs.removeAll()
        tabLoadedAt.removeAll()
        isLoadingTab.removeAll()
        loadingFeedbackBuildIds = []
    }

    func refreshTabData(_ tab: AppTab) async {
        if let task = tabLoadTasks[tab] { await task.value; return }
        guard let service, credentials != nil, app != nil, !restoringCache else { return }
        let revision = projectRevision
        let hadLoadedData = loadedTabs.contains(tab)
        cancelBackgroundHydration(for: tab)
        isLoadingTab[tab] = true
        tabError.removeValue(forKey: tab)
        let task = Task { [self] in
            defer {
                if projectRevision == revision {
                    isLoadingTab[tab] = false
                    tabLoadTasks.removeValue(forKey: tab)
                }
            }
            do {
                try await loadData(for: tab, service: service)
                guard projectRevision == revision, !Task.isCancelled else { return }
                loadedTabs.insert(tab)
                tabLoadedAt[tab] = Date()
            } catch {
                guard projectRevision == revision, !Task.isCancelled else { return }
                if !hadLoadedData {
                    loadedTabs.remove(tab)
                    tabLoadedAt.removeValue(forKey: tab)
                }
                tabError[tab] = error.localizedDescription
                await logDataFetchFailure("asc_tab_refresh_failed", error: error, metadata: ["tab": tab.rawValue])
            }
        }
        tabLoadTasks[tab] = task
        await task.value
    }

    func refreshSubmissionReadinessData() async {
        let revision = projectRevision
        await refreshCurrentApp()
        guard projectRevision == revision, !Task.isCancelled else { return }
        await refreshMonetization()
        guard projectRevision == revision, !Task.isCancelled else { return }
        await refreshAttachedSubmissionItemIDs()
    }

    func syncOverviewSubmissionReadiness(forceRefresh: Bool = false) async {
        let revision = projectRevision
        if forceRefresh {
            await refreshTabData(.app)
        } else {
            await ensureTabData(.app)
        }
        guard projectRevision == revision, !Task.isCancelled else { return }
        await waitForBackgroundHydration(for: .app)
        guard projectRevision == revision, !Task.isCancelled else { return }
        await refreshSubmissionReadinessData()
    }

    func startOverviewReadinessLoading(_ fields: Set<String>) {
        overviewReadinessLoadingFields.formUnion(fields)
    }

    func finishOverviewReadinessLoading(_ fields: Set<String>) {
        overviewReadinessLoadingFields.subtract(fields)
        overviewFailedFields.subtract(fields)
        overviewResolvedFields.formUnion(fields)
    }

    func isCurrentProject(_ projectId: String?) -> Bool {
        guard let projectId else { return false }
        return loadedProjectId == projectId
    }

    private func refreshCurrentApp() async {
        guard let service, let appId = app?.id else { return }
        let revision = projectRevision
        if let refreshedApp = try? await service.fetchApp(id: appId), projectRevision == revision, !Task.isCancelled {
            app = refreshedApp
        }
    }

    private func hydrateReviewSecondaryData(
        projectId: String?,
        appId: String,
        appInfoId: String?,
        service: AppStoreConnectService
    ) async {
        if let appInfoId {
            let fetchedAgeRating = await fetchAgeRatingLogged(
                service: service,
                appInfoId: appInfoId,
                context: "review_secondary"
            )
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            ageRatingDeclaration = fetchedAgeRating
        } else {
            ageRatingDeclaration = nil
        }

        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        await refreshReviewSubmissionData(appId: appId, service: service)
        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        rebuildSubmissionHistory(appId: appId)
        refreshSubmissionFeedbackIfNeeded()
    }

    private func hydrateMonetizationSecondaryData(
        projectId: String?,
        appId: String,
        groups: [ASCSubscriptionGroup],
        service: AppStoreConnectService
    ) async {
        do {
            let fetchedSubscriptions = try await withThrowingTaskGroup(of: (String, [ASCSubscription]).self) { taskGroup in
                for subscriptionGroup in groups {
                    taskGroup.addTask {
                        let subscriptions = try await service.fetchSubscriptionsInGroup(groupId: subscriptionGroup.id)
                        return (subscriptionGroup.id, subscriptions)
                    }
                }

                var pairs: [(String, [ASCSubscription])] = []
                for try await pair in taskGroup {
                    pairs.append(pair)
                }
                return pairs
            }

            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            subscriptionsPerGroup = Dictionary(uniqueKeysWithValues: fetchedSubscriptions)
        } catch {
            print("Failed to hydrate monetization subscriptions: \(error)")
        }

        if currentAppPricePointId == nil && scheduledAppPricePointId == nil && monetizationStatus == nil {
            let hasPricing = await fetchPricingConfiguredLogged(
                service: service,
                appId: appId,
                context: "monetization_secondary"
            )
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            monetizationStatus = hasPricing ? "Configured" : nil
        }
    }

    private func hydrateFeedbackSecondaryData(
        projectId: String?,
        buildId: String,
        service: AppStoreConnectService
    ) async {
        guard isCurrentProject(projectId) else { return }
        guard !Task.isCancelled else { return }
        loadingFeedbackBuildIds.insert(buildId)
        defer { loadingFeedbackBuildIds.remove(buildId) }

        do {
            let items = try await service.fetchBetaFeedback(buildId: buildId)
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            betaFeedback[buildId] = items
        } catch {
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            betaFeedback[buildId] = []
        }
    }

    private func loadData(for tab: AppTab, service: AppStoreConnectService) async throws {
        guard let appId = app?.id else {
            throw ASCError.notFound("App - check your bundle ID in project settings")
        }

        switch tab {
        case .app:
            let revision = projectRevision
            await loadOverview(using: service)
            guard projectRevision == revision, !Task.isCancelled else { return }
            startBackgroundHydration(for: .app) {
                guard self.projectRevision == revision else { return }
                async let products: Void = self.loadOverviewProducts(service: service, appId: appId, revision: revision)
                await self.refreshReviewSubmissionData(appId: appId, service: service)
                _ = await products
                guard self.projectRevision == revision, !Task.isCancelled else { return }
                self.rebuildSubmissionHistory(appId: appId)
                self.refreshSubmissionFeedbackIfNeeded()
            }

        case .appInformation:
            let revision = projectRevision
            async let appInfoTask: ASCAppInfo? = try? await service.fetchAppInfo(appId: appId)
            async let appRefreshTask: ASCApp? = try? service.fetchApp(id: appId)
            try await refreshAppInformationMetadata(
                service: service,
                appId: appId,
                preferredVersionId: selectedVersionId,
                preferredLocale: selectedAppInformationLocale
            )
            let refreshedInfo = await appInfoTask
            let refreshedApp = await appRefreshTask
            guard projectRevision == revision, !Task.isCancelled else { throw CancellationError() }
            if let refreshedInfo { appInfo = refreshedInfo }
            if let refreshedApp { app = refreshedApp }

        case .screenshots:
            let versions = try await service.fetchAppStoreVersions(appId: appId)
            appStoreVersions = versions
            syncSelectedVersion()
            if let selectedVersionId = selectedVersion?.id {
                let localizations = try await service.fetchLocalizations(versionId: selectedVersionId)
                self.localizations = localizations
                let preferredLocale = selectedScreenshotsLocale
                let targetLocalization = localizations.first(where: { $0.attributes.locale == preferredLocale })
                    ?? localizations.first
                if let targetLocalization {
                    selectedScreenshotsLocale = targetLocalization.attributes.locale
                    await loadScreenshots(locale: targetLocalization.attributes.locale, force: true)
                } else {
                    screenshotSetsByLocale = [:]
                    screenshotsByLocale = [:]
                    selectedScreenshotsLocale = nil
                }
            } else {
                localizations = []
                screenshotSetsByLocale = [:]
                screenshotsByLocale = [:]
                selectedScreenshotsLocale = nil
            }

        case .review:
            async let versionsTask = service.fetchAppStoreVersions(appId: appId)
            async let appInfoTask: ASCAppInfo? = try? await service.fetchAppInfo(appId: appId)
            async let buildsTask = service.fetchBuilds(appId: appId)

            let versions = try await versionsTask
            appStoreVersions = versions
            syncSelectedVersion()
            if let selectedVersionId = selectedVersion?.id {
                reviewDetail = await fetchReviewDetailLogged(
                    service: service,
                    versionId: selectedVersionId,
                    context: "review_tab_load"
                )
                selectedVersionBuild = try? await service.fetchBuildAttachedToVersion(versionId: selectedVersionId)
            } else {
                reviewDetail = nil
                selectedVersionBuild = nil
            }
            appInfo = await appInfoTask
            builds = try await buildsTask
            let projectId = loadedProjectId
            let currentAppInfoId = appInfo?.id
            startBackgroundHydration(for: .review) {
                await self.hydrateReviewSecondaryData(
                    projectId: projectId,
                    appId: appId,
                    appInfoId: currentAppInfoId,
                    service: service
                )
            }

        case .monetization:
            async let pricePointsTask = service.fetchAppPricePoints(appId: appId)
            async let pricingStateTask = fetchAppPricingStateLogged(
                service: service,
                appId: appId,
                context: "monetization_tab_load"
            )
            async let iapTask = service.fetchInAppPurchases(appId: appId)
            async let groupsTask = service.fetchSubscriptionGroups(appId: appId)

            appPricePoints = try await pricePointsTask
            applyAppPricingState(
                await pricingStateTask
                    ?? ASCAppPricingState(
                        currentPricePointId: nil,
                        scheduledPricePointId: nil,
                        scheduledEffectiveDate: nil
                    )
            )
            inAppPurchases = try await iapTask
            let groups = try await groupsTask
            subscriptionGroups = groups

            let projectId = loadedProjectId
            startBackgroundHydration(for: .monetization) {
                await self.hydrateMonetizationSecondaryData(
                    projectId: projectId,
                    appId: appId,
                    groups: groups,
                    service: service
                )
            }

        case .analytics:
            break

        case .reviews:
            customerReviews = try await service.fetchCustomerReviews(appId: appId)

        case .builds:
            builds = try await service.fetchBuilds(appId: appId)

        case .groups:
            betaGroups = try await service.fetchBetaGroups(appId: appId)

        case .betaInfo:
            betaLocalizations = try await service.fetchBetaLocalizations(appId: appId)

        case .feedback:
            let fetchedBuilds = try await service.fetchBuilds(appId: appId)
            builds = fetchedBuilds
            let resolvedBuildId: String?
            if let currentSelectedBuildId = selectedBuildId,
               fetchedBuilds.contains(where: { $0.id == currentSelectedBuildId }) {
                resolvedBuildId = currentSelectedBuildId
            } else {
                resolvedBuildId = fetchedBuilds.first?.id
            }
            selectedBuildId = resolvedBuildId
            if let resolvedBuildId {
                let projectId = loadedProjectId
                startBackgroundHydration(for: .feedback) {
                    await self.hydrateFeedbackSecondaryData(
                        projectId: projectId,
                        buildId: resolvedBuildId,
                        service: service
                    )
                }
            } else {
                betaFeedback = [:]
            }

        default:
            break
        }
    }
}
