import Foundation

extension ASCManager {
    func restoreTabCacheIfNeeded(_ tab: AppTab) async {
        guard ASCTabCacheEntry.tabs.contains(tab), !loadedTabs.contains(tab), !restoringCache,
              let appId = app?.id, let account = DashboardSummaryStore.accountKey(for: credentials) else { return }
        if let task = tabCacheRestoreTasks[tab] { await task.value; return }
        guard !tabCacheRestoreAttempted.contains(tab) else { return }
        let revision = projectRevision
        let version = ASCTabCacheEntry.versionScoped.contains(tab) ? selectedVersion?.id : nil
        let task = Task { [self] in
            let saved = await tabCache.load(account: account, appId: appId, tab: tab, versionId: version)
            guard projectRevision == revision, !Task.isCancelled else { return }
            if !loadedTabs.contains(tab) { saved?.apply(to: self, tab: tab) }
            tabCacheRestoreAttempted.insert(tab)
            tabCacheRestoreTasks.removeValue(forKey: tab)
        }
        tabCacheRestoreTasks[tab] = task
        await task.value
    }

    func persistTabCache(_ tab: AppTab) async {
        guard let account = DashboardSummaryStore.accountKey(for: credentials),
              let entry = ASCTabCacheEntry(manager: self, tab: tab) else { return }
        await tabCache.save(entry, account: account)
    }

    /// Overview already fetched these resources; opening their editors must not
    /// repeat the same successful requests just because the tab has changed.
    func shareOverviewDataWithTabs(includeBuilds: Bool) async {
        let revision = projectRevision
        var tabs: [AppTab] = includeBuilds ? [.appInformation, .builds] : [.appInformation]
        if let locale = selectedScreenshotsLocale ?? primaryAppInformationLocale(),
           let date = screenshotLoadedAt[screenshotCacheKey(locale: locale)], Date().timeIntervalSince(date) < 120 {
            tabs.append(.screenshots)
        }
        for tab in tabs where tabLoadTasks[tab] == nil {
            loadedTabs.insert(tab)
            tabLoadedAt[tab] = Date()
            tabsNeedingRevalidation.remove(tab)
            await persistTabCache(tab)
            guard projectRevision == revision, !Task.isCancelled else { return }
        }
    }

    func resetTabCacheTasks() {
        for task in tabCacheRestoreTasks.values { task.cancel() }
        tabCacheRestoreTasks.removeAll()
        tabCacheRestoreAttempted.removeAll()
        tabsNeedingRevalidation.removeAll()
        for task in screenshotLoadTasks.values { task.cancel() }
        screenshotLoadTasks.removeAll()
        screenshotForcedLoads.removeAll()
        for task in feedbackLoadTasks.values { task.cancel() }
        feedbackLoadTasks.removeAll()
        feedbackLoadedAt.removeAll()
        screenshotLoadedAt.removeAll()
    }
}
