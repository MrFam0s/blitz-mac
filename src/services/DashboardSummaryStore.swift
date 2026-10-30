import Foundation

/// A single app row on the Dashboard > My Apps page.
///
/// Unifies two worlds:
/// - ASC-native apps (what the user has on App Store Connect — the primary list).
/// - Local-only projects that haven't been linked to an ASC record yet.
struct DashboardAppRow: Codable, Identifiable, Sendable, Equatable {
    enum Source: String, Codable, Sendable {
        case asc        // pulled from App Store Connect (may or may not have a local project)
        case localOnly  // local project without a matching ASC app
    }

    let id: String           // bundleId if known, otherwise "local:<projectId>"
    let bundleId: String?
    let name: String
    let source: Source
    let ascAppId: String?
    let linkedProjectId: String?
    let status: ASCDashboardProjectStatus?
    let iconURL: URL?

    static func asc(
        app: ASCApp,
        status: ASCDashboardProjectStatus?,
        linkedProjectId: String?,
        iconURL: URL?
    ) -> DashboardAppRow {
        DashboardAppRow(
            id: app.bundleId,
            bundleId: app.bundleId,
            name: app.name,
            source: .asc,
            ascAppId: app.id,
            linkedProjectId: linkedProjectId,
            status: status,
            iconURL: iconURL
        )
    }

    static func localOnly(project: Project) -> DashboardAppRow {
        DashboardAppRow(
            id: "local:\(project.id)",
            bundleId: project.metadata.bundleIdentifier,
            name: project.name,
            source: .localOnly,
            ascAppId: nil,
            linkedProjectId: project.id,
            status: nil,
            iconURL: nil
        )
    }
}

@MainActor
@Observable
final class DashboardSummaryStore {
    static let shared = DashboardSummaryStore()

    private static let freshness: TimeInterval = 120

    private struct Snapshot: Codable {
        let accountKey: String
        let summary: ASCDashboardSummary
        let projectStatuses: [String: ASCDashboardProjectStatus]
        let ascApps: [ASCApp]?
        let appRows: [DashboardAppRow]
        let refreshedAt: Date?
        let unavailableStatusBundleIDs: Set<String>?
    }

    var summary = ASCDashboardSummary.empty
    var projectStatuses: [String: ASCDashboardProjectStatus] = [:]
    var ascApps: [ASCApp] = []
    var appRows: [DashboardAppRow] = []
    var hasLoadedSummary = false
    var isLoadingSummary = false
    var loadingSummaryStatusText: String?

    private(set) var iconRefreshRevision = 0
    private(set) var cacheKey: String?
    private(set) var refreshedAt: Date?
    private(set) var loadIssue: DashboardLoadIssue?
    private(set) var isShowingSavedData = false
    private(set) var unavailableStatusBundleIDs: Set<String> = []
    private var revision = 0
    private var loadedAccountKey: String?
    private let cacheURL: URL
    private let accountKeyOverride: String?

    init(
        cacheURL: URL? = nil,
        accountKeyOverride: String? = nil
    ) {
        self.cacheURL = cacheURL ?? Self.persistentCacheURL()
        self.accountKeyOverride = accountKeyOverride
        restorePersistentCacheIfPossible()
    }

    static func accountKey(for credentials: ASCCredentials?) -> String? {
        guard let credentials else { return nil }
        return "\(credentials.issuerId):\(credentials.keyId)"
    }

    static func cacheKey(accountKey: String?, credentialActivationRevision: Int) -> String {
        "\(accountKey ?? "no-creds"):\(credentialActivationRevision)"
    }

    func shouldRefresh(for key: String) -> Bool {
        guard loadIssue == nil, !isShowingSavedData, cacheKey == key, let refreshedAt else { return true }
        return Date().timeIntervalSince(refreshedAt) > Self.freshness
    }

    func isLoading(for key: String) -> Bool {
        isLoadingSummary && cacheKey == key
    }

    func beginLoading(for key: String, accountKey: String?) {
        revision += 1
        if shouldResetLoadedState(for: accountKey) {
            reset()
        }
        cacheKey = key
        loadedAccountKey = accountKey
        isLoadingSummary = true
        loadingSummaryStatusText = "Loading apps from App Store Connect…"
    }

    func store(
        summary: ASCDashboardSummary,
        projectStatuses: [String: ASCDashboardProjectStatus],
        ascApps: [ASCApp],
        appRows: [DashboardAppRow],
        for key: String,
        accountKey: String?,
        unavailableStatusBundleIDs: Set<String> = []
    ) {
        revision += 1
        self.unavailableStatusBundleIDs = unavailableStatusBundleIDs
        loadIssue = unavailableStatusBundleIDs.isEmpty ? nil : .partialStatuses(unavailableStatusBundleIDs.count)
        isShowingSavedData = false
        self.summary = summary
        self.projectStatuses = projectStatuses
        self.ascApps = ascApps
        self.appRows = appRows
        hasLoadedSummary = true
        cacheKey = key
        refreshedAt = Date()
        loadedAccountKey = accountKey
        isLoadingSummary = false
        loadingSummaryStatusText = nil
        persistCacheIfPossible(accountKey: accountKey)
    }

    func markEmpty(for key: String, accountKey: String?) {
        revision += 1
        loadIssue = nil
        isShowingSavedData = false
        unavailableStatusBundleIDs = []
        summary = .empty
        projectStatuses = [:]
        ascApps = []
        appRows = []
        hasLoadedSummary = true
        cacheKey = key
        refreshedAt = Date()
        loadedAccountKey = accountKey
        isLoadingSummary = false
        loadingSummaryStatusText = nil
        persistCacheIfPossible(accountKey: accountKey)
    }

    func markUnavailable(for key: String, accountKey: String?, issue: DashboardLoadIssue = .unavailable) {
        revision += 1
        if shouldResetLoadedState(for: accountKey) {
            reset()
            loadedAccountKey = accountKey
        }
        cacheKey = key
        loadIssue = issue
        isShowingSavedData = hasLoadedSummary
        isLoadingSummary = false
        loadingSummaryStatusText = nil
    }

    func cancelLoading(for key: String) {
        guard cacheKey == key else { return }
        isLoadingSummary = false
        loadingSummaryStatusText = nil
    }

    /// Explicit refresh also updates icons whose project path or remote URL is unchanged.
    func refreshIcons(for projects: [Project]) {
        iconRefreshRevision += 1
        for project in projects {
            ProjectAppIconLoader.invalidate(for: project.id)
        }
    }

    func refresh(
        for key: String,
        accountKey: String?,
        service: any DashboardFetching,
        projects: [Project],
        force: Bool = false
    ) async {
        if isLoading(for: key) || (!force && !shouldRefresh(for: key)) {
            return
        }

        if force { refreshIcons(for: projects) }
        beginLoading(for: key, accountKey: accountKey)
        let token = revision

        let allAscApps: [ASCApp]
        do {
            allAscApps = try await service.fetchAllApps(appStoreStateFilter: nil)
        } catch {
            guard revision == token else { return }
            if Task.isCancelled || error is CancellationError {
                cancelLoading(for: key)
            } else {
                markUnavailable(for: key, accountKey: accountKey, issue: .from(error))
            }
            return
        }

        guard revision == token else { return }
        if Task.isCancelled {
            cancelLoading(for: key)
            return
        }

        if allAscApps.isEmpty {
            markEmpty(for: key, accountKey: accountKey)
            return
        }

        var nextSummary = ASCDashboardSummary.empty
        var nextStatuses: [String: ASCDashboardProjectStatus] = [:]
        var nextIconURLs = currentIconURLsByBundleId()
        var completedCount = 0
        loadingSummaryStatusText = "Loading apps 0/\(allAscApps.count)…"

        let concurrencyLimit = 6
        var perAppStatuses: [String: ASCDashboardProjectStatus] = [:]
        await withTaskGroup(of: (String, ASCDashboardProjectStatus?, URL?).self) { group in
            var iterator = allAscApps.makeIterator()

            func enqueueNext() {
                guard let next = iterator.next() else { return }
                let bundleId = next.bundleId
                group.addTask {
                    var status: ASCDashboardProjectStatus?
                    var iconURL: URL?

                    do {
                        let versions = try await service.fetchAppStoreVersions(appId: next.id)
                        status = ASCDashboardProjectStatus(versions: versions)
                    } catch {
                        status = nil
                    }

                    do {
                        iconURL = try await service.fetchAppStoreIconURL(app: next, dimension: 1024)
                    } catch {
                        iconURL = nil
                    }

                    return (bundleId, status, iconURL)
                }
            }

            for _ in 0..<min(concurrencyLimit, allAscApps.count) {
                enqueueNext()
            }

            while let result = await group.next() {
                guard revision == token, !Task.isCancelled else { group.cancelAll(); break }
                if let status = result.1 {
                    perAppStatuses[result.0] = status
                }
                if let iconURL = result.2 {
                    nextIconURLs[result.0] = iconURL
                }
                completedCount += 1
                loadingSummaryStatusText = "Loading apps \(completedCount)/\(allAscApps.count)…"
                if Task.isCancelled { break }
                enqueueNext()
            }
        }

        guard revision == token else { return }
        if Task.isCancelled {
            cancelLoading(for: key)
            return
        }

        let unavailable = Set(allAscApps.map(\.bundleId)).subtracting(perAppStatuses.keys)
        for app in allAscApps {
            if let status = perAppStatuses[app.bundleId] ?? projectStatuses[app.bundleId] {
                nextSummary.include(status)
                nextStatuses[app.bundleId] = status
            }
        }

        store(
            summary: nextSummary,
            projectStatuses: nextStatuses,
            ascApps: allAscApps,
            appRows: rows(
                linking: projects,
                ascApps: allAscApps,
                projectStatuses: nextStatuses,
                iconURLs: nextIconURLs
            ),
            for: key,
            accountKey: accountKey,
            unavailableStatusBundleIDs: unavailable
        )
    }

    private func shouldResetLoadedState(for accountKey: String?) -> Bool {
        loadedAccountKey != accountKey
    }

    private func reset() {
        summary = .empty
        projectStatuses = [:]
        ascApps = []
        appRows = []
        hasLoadedSummary = false
        refreshedAt = nil
        loadIssue = nil
        isShowingSavedData = false
        unavailableStatusBundleIDs = []
        loadingSummaryStatusText = nil
    }

    private func restorePersistentCacheIfPossible() {
        guard let accountKey = activeAccountKey(),
              let data = try? Data(contentsOf: cacheURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.accountKey == accountKey else {
            return
        }

        refreshedAt = snapshot.refreshedAt
        unavailableStatusBundleIDs = snapshot.unavailableStatusBundleIDs ?? []
        if !unavailableStatusBundleIDs.isEmpty { loadIssue = .partialStatuses(unavailableStatusBundleIDs.count) }
        isShowingSavedData = true
        summary = snapshot.summary
        projectStatuses = snapshot.projectStatuses
        ascApps = snapshot.ascApps ?? restoredASCApps(from: snapshot.appRows)
        appRows = snapshot.appRows
        hasLoadedSummary = true
        loadedAccountKey = accountKey
    }

    private func persistCacheIfPossible(accountKey: String?) {
        guard let accountKey else { return }

        let snapshot = Snapshot(
            accountKey: accountKey,
            summary: summary,
            projectStatuses: projectStatuses,
            ascApps: ascApps,
            appRows: appRows,
            refreshedAt: refreshedAt,
            unavailableStatusBundleIDs: unavailableStatusBundleIDs
        )

        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // A failed cache write should only cost us a warm start, not the dashboard itself.
        }
    }

    private func activeAccountKey() -> String? {
        accountKeyOverride ?? Self.accountKey(for: ASCCredentials.load())
    }

    func rows(linking projects: [Project]) -> [DashboardAppRow] {
        rows(
            linking: projects,
            ascApps: ascApps,
            projectStatuses: projectStatuses,
            iconURLs: currentIconURLsByBundleId()
        )
    }

    func rows(
        linking projects: [Project],
        ascApps: [ASCApp],
        projectStatuses: [String: ASCDashboardProjectStatus],
        iconURLs: [String: URL]
    ) -> [DashboardAppRow] {
        var projectsByBundleId: [String: Project] = [:]
        for project in projects {
            if let bundleId = project.metadata.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !bundleId.isEmpty {
                projectsByBundleId[bundleId] = project
            }
        }

        var linkedBundleIds: Set<String> = []
        let ascRows = ascApps.map { app in
            let linkedProjectId = projectsByBundleId[app.bundleId]?.id
            if linkedProjectId != nil {
                linkedBundleIds.insert(app.bundleId)
            }
            return DashboardAppRow.asc(
                app: app,
                status: projectStatuses[app.bundleId],
                linkedProjectId: linkedProjectId,
                iconURL: iconURLs[app.bundleId]
            )
        }

        var localOnlyRows: [DashboardAppRow] = []
        for project in projects {
            let bundleId = project.metadata.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if bundleId.isEmpty || !linkedBundleIds.contains(bundleId) {
                localOnlyRows.append(DashboardAppRow.localOnly(project: project))
            }
        }

        return ascRows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            + localOnlyRows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func restoredASCApps(from rows: [DashboardAppRow]) -> [ASCApp] {
        rows.compactMap { row in
            guard row.source == .asc,
                  let bundleId = row.bundleId,
                  let ascAppId = row.ascAppId else {
                return nil
            }
            return ASCApp(
                id: ascAppId,
                attributes: ASCApp.Attributes(
                    bundleId: bundleId,
                    name: row.name,
                    primaryLocale: nil,
                    vendorNumber: nil,
                    contentRightsDeclaration: nil
                ),
                relationships: nil
            )
        }
    }

    private func currentIconURLsByBundleId() -> [String: URL] {
        var iconURLs: [String: URL] = [:]
        for row in appRows {
            guard row.source == .asc,
                  let bundleId = row.bundleId,
                  let iconURL = row.iconURL else {
                continue
            }
            iconURLs[bundleId] = iconURL
        }
        return iconURLs
    }

    private static func persistentCacheURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return baseURL
            .appendingPathComponent("Blitz", isDirectory: true)
            .appendingPathComponent("dashboard-my-apps-cache.json")
    }
}
