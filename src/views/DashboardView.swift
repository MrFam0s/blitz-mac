import SwiftUI

struct DashboardView: View {
    @Bindable var appState: AppState
    @State private var dashboardSummary = DashboardSummaryStore.shared
    @State private var visibility = DashboardVisibilityStore.shared
    @State private var searchText = ""
    @State private var showsHiddenApps = false
    @State private var lastHiddenApp: DashboardAppRow?
    @State private var visibilityError: String?
    @AppStorage("dashboard.sortField") private var sortField = DashboardAppSortField.name
    @AppStorage("dashboard.sortDirection") private var sortDirection = DashboardAppSortDirection.ascending
    @AppStorage("dashboard.entryIconSize") private var storedIconSize = DashboardEntrySize.defaultIconSize
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    private var entrySize: DashboardEntrySize { DashboardEntrySize(storedIconSize) }

    private var projects: [Project] { appState.projectManager.projects }

    private var dashboardAccountKey: String? {
        DashboardSummaryStore.accountKey(
            for: appState.ascManager.credentials ?? ASCCredentials.load()
        )
    }

    /// Only the ASC account identity and explicit credential activation should
    /// restart the network hydration task. Local project changes are linked in
    /// memory and should not cancel an in-flight ASC fetch.
    private var summaryHydrationKey: String {
        DashboardSummaryStore.cacheKey(
            accountKey: dashboardAccountKey,
            credentialActivationRevision: appState.ascManager.credentialActivationRevision
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Dashboard controls
            topNavbar
                .blitzToolbar()

            Divider()

            // Apps
            myAppsContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(L10n.tr("Dashboard konnte nicht aktualisiert werden"), isPresented: Binding(
            get: { visibilityError != nil },
            set: { if !$0 { visibilityError = nil } }
        )) {
            Button("OK", role: .cancel) { visibilityError = nil }
        } message: {
            Text(visibilityError ?? "")
        }
    }

    // MARK: - Dashboard header

    private var topNavbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                dashboardTitle
                Spacer(minLength: 12)
                searchField.frame(width: 180)
                sortControl
                dashboardTools
            }
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        dashboardTitle
                        Spacer(minLength: 0)
                        searchField.frame(width: 128)
                        dashboardTools
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            dashboardTitle
                            Spacer(minLength: 0)
                            dashboardTools
                        }
                        searchField
                    }
                }
                sortControl
            }
        }
    }

    private var dashboardTitle: some View {
        Text(showsHiddenApps ? L10n.tr("Ausgeblendete Apps") : L10n.tr("Meine Apps"))
            .font(BlitzLayout.pageTitle)
            .foregroundStyle(.primary)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }

    private var sortControl: some View {
        DashboardSortControl(field: $sortField, direction: $sortDirection)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L10n.tr("Apps suchen"), text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel(L10n.tr("Apps nach Name oder Bundle-ID suchen"))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Suche leeren"))
                .help(L10n.tr("Suche leeren"))
            }
        }
        .font(BlitzLayout.toolbarFont)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var dashboardTools: some View {
        HStack(spacing: 4) {
            Button { showsHiddenApps.toggle() } label: {
                Image(systemName: showsHiddenApps ? "arrow.uturn.backward" : "eye.slash")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(hiddenAppsTitle)
            .help(hiddenAppsTitle)

            Button { forceRefreshApps() } label: {
                ZStack {
                    if isRefreshingApps {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .disabled(isRefreshingApps)
            .accessibilityLabel(L10n.tr("Apps aktualisieren"))
            .accessibilityValue(isRefreshingApps ? summaryLoadingStatusText : "")
            .help(isRefreshingApps ? summaryLoadingStatusText : refreshButtonHelpText)
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private var hiddenAppsTitle: String {
        showsHiddenApps ? L10n.tr("Zurück zu meinen Apps") : L10n.tr("Ausgeblendete Apps (\(hiddenAppCount))")
    }

    private var appRows: [DashboardAppRow] { dashboardSummary.rows(linking: projects) }
    private var visibleSummary: ASCDashboardSummary {
        var summary = ASCDashboardSummary.empty
        for row in appRows where !visibility.isHidden(row) {
            if let status = row.status { summary.include(status) }
        }
        return summary
    }
    private var hiddenAppCount: Int { appRows.filter { visibility.isHidden($0) }.count }
    private var displayedRows: [DashboardAppRow] {
        DashboardAppOrdering.sorted(
            appRows.filter { visibility.isHidden($0) == showsHiddenApps && $0.matches(searchText: searchText) },
            by: sortField,
            direction: sortDirection,
            unavailableStatusBundleIDs: dashboardSummary.unavailableStatusBundleIDs
        )
    }
    private var isLoadingInitialSummary: Bool {
        dashboardSummary.isLoadingSummary && !dashboardSummary.hasLoadedSummary
    }
    private var summaryLoadingStatusText: String {
        dashboardSummary.loadingSummaryStatusText ?? L10n.tr("Apps werden geladen …")
    }
    private var isRefreshingApps: Bool {
        dashboardSummary.isLoading(for: summaryHydrationKey)
    }
    private var refreshButtonHelpText: String {
        guard let date = dashboardSummary.refreshedAt else { return L10n.tr("Apps aktualisieren") }
        return L10n.tr("Apps aktualisieren · Zuletzt aktualisiert \(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))")
    }

    private var myAppsContent: some View {
        let sections = DashboardAppOrdering.platformSections(for: displayedRows)
        return ScrollView {
            VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                if showsHiddenApps {
                    Text(L10n.tr("Ausgeblendete Apps bleiben in App Store Connect und auf dem Mac erhalten. Du kannst sie hier wieder einblenden."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(summaryLine)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if !sections.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: entrySize.minimumColumnWidth), spacing: 20, alignment: .leading)],
                        alignment: .leading, spacing: 6
                    ) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.rows) { row in appCard(row: row) }
                            } header: {
                                HStack(spacing: 10) {
                                    Text(section.id.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .accessibilityAddTraits(.isHeader)
                                    VStack { Divider() }
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal, 8)
                                .padding(.top, section.id == sections.first?.id ? 0 : 8)
                            }
                        }
                    }
                } else if isLoadingInitialSummary {
                    Text(summaryLoadingStatusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else if dashboardSummary.loadIssue == nil || dashboardSummary.hasLoadedSummary || !appRows.isEmpty {
                    emptyStateView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .blitzPagePadding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let issue = dashboardSummary.loadIssue {
                    dashboardRefreshStatus(issue)
                }
                if let lastHiddenApp {
                    HStack(alignment: .top, spacing: 8) {
                        Text(L10n.tr("\(lastHiddenApp.name) wurde im Dashboard ausgeblendet."))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(L10n.tr("Rückgängig")) { setHidden(false, for: lastHiddenApp) }
                        Button { self.lastHiddenApp = nil } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("Schließen"))
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        entrySizeControl
                        Spacer(minLength: 0)
                        projectActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        entrySizeControl
                        projectActions.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .blitzToolbar()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .task(id: summaryHydrationKey) {
            await hydrateSummary()
        }
    }

    private var entrySizeControl: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("Größe"))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { entrySize.icon }, set: { storedIconSize = $0 }),
                   in: DashboardEntrySize.iconRange, step: DashboardEntrySize.step) {
                Text(L10n.tr("Größe der App-Einträge"))
            }
            .labelsHidden()
            .frame(width: 88)
            .accessibilityValue(L10n.tr("\(Int(entrySize.icon)) Punkte"))
        }
        .fixedSize()
        .help(L10n.tr("App-Icons und Schrift gemeinsam skalieren"))
    }

    private var projectActions: some View {
        HStack(spacing: 12) {
            Button(L10n.tr("Neues Projekt")) { appState.showNewProjectSheet = true }
                .buttonStyle(.borderedProminent)
            Button(L10n.tr("Projekt importieren")) { appState.showImportProjectSheet = true }
                .buttonStyle(.bordered)
        }
        .controlSize(.regular)
        .fixedSize()
    }

    private func dashboardRefreshStatus(_ issue: DashboardLoadIssue) -> some View {
        DashboardRefreshStatusView(
            issueTitle: issue.title,
            issueMessage: issue.message,
            needsSettings: issue.needsSettings,
            isShowingSavedData: dashboardSummary.isShowingSavedData,
            isLoading: dashboardSummary.isLoadingSummary,
            retry: { forceRefreshApps() },
            openSettings: { appState.activeTab = .settings }
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(!searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? L10n.tr("Keine passenden Apps") : (showsHiddenApps ? L10n.tr("Keine ausgeblendeten Apps") : L10n.tr("Keine Apps vorhanden")))
                .font(.headline)
            Text(!searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? L10n.tr("Versuche einen anderen Namen oder eine andere Bundle-ID.")
                 : (showsHiddenApps ? L10n.tr("Hier erscheinen Apps, die du im Dashboard ausblendest.")
                    : (hiddenAppCount > 0 ? L10n.tr("Blende eine App wieder ein oder importiere ein weiteres Projekt.")
                       : L10n.tr("Erstelle ein neues Projekt oder importiere ein vorhandenes."))))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var summaryLine: String {
        let counts = visibleSummary
        return L10n.tr("\(statValue(counts.liveCount)) im App Store · \(statValue(counts.pendingCount)) in Prüfung · \(statValue(counts.rejectedCount)) abgelehnt")
    }

    // MARK: - App Card

    @ViewBuilder
    private func appCard(row: DashboardAppRow) -> some View {
        let isSelected = row.projectLinks?.contains(where: {
            $0.projectId == appState.activeProjectId && $0.targetId == appState.activeProject?.selectedReleaseTarget?.id
        }) ?? (row.linkedProjectId != nil && row.linkedProjectId == appState.activeProjectId)
        let project = row.linkedProjectId.flatMap { id in projects.first(where: { $0.id == id }) }

        let status = DashboardAppOrdering.status(for: row, unavailableStatusBundleIDs: dashboardSummary.unavailableStatusBundleIDs)
        let statuses = row.dashboardStatuses(primary: status)
        let caption = statuses.map(\.title).joined(separator: " · ")
        let platform = DashboardPlatformPresentation.title(row.platformCodes)
        let metadata = statuses.reduce(Text(verbatim: platform).foregroundColor(.secondary)) { text, status in
            let separator = Text(verbatim: " · ").foregroundColor(.secondary)
            return Text("\(text)\(separator)\(status.markedTitle)")
        }
        let platformHelp = row.dashboardPlatformHelp(includeStatuses: status != .unknown)
        let details = [platformHelp, caption, sortField == .modified ? row.dashboardDateHelp : nil]
            .compactMap { $0 }.joined(separator: "\n")

        Button { selectRow(row) } label: {
            appCardContent(row: row, project: project, metadata: metadata)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(isSelected ? Color.accentColor.opacity(0.09) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("\(row.name) öffnen"))
        .accessibilityValue(details)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if let links = row.projectLinks, links.count > 1 {
                ForEach(links) { link in
                    Button("\(projects.first { $0.id == link.projectId }?.name ?? link.projectId) · \(link.platform.rawValue)") {
                        selectLinkedTarget(link)
                    }
                }
                Divider()
            }
            visibilityAction(for: row)
        }
        .help([row.name, row.bundleId, platformHelp, caption, row.dashboardDateHelp]
            .compactMap { $0 }.joined(separator: "\n"))
    }

    private func appCardContent(row: DashboardAppRow, project: Project?, metadata: Text) -> some View {
        HStack(alignment: .center, spacing: 11) {
            Group {
                if let project {
                    ProjectAppIconView(project: project, size: entrySize.icon, cornerRadius: entrySize.cornerRadius) {
                        ascIcon(for: row)
                    }
                } else {
                    ascIcon(for: row)
                }
            }
            .frame(width: entrySize.icon, height: entrySize.icon)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.system(size: entrySize.nameSize * textScale, weight: .medium))
                    .lineLimit(2)

                metadata
                    .font(.system(size: entrySize.captionSize * textScale))

                if sortField == .modified {
                    DashboardDateCaption(row: row, font: .system(size: (entrySize.captionSize - 1) * textScale))
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    @ViewBuilder
    private func ascIcon(for row: DashboardAppRow) -> some View {
        if let iconURL = row.iconURL {
            DashboardRemoteIconView(url: iconURL, refreshRevision: dashboardSummary.iconRefreshRevision,
                                    cornerRadius: entrySize.cornerRadius) {
                fallbackIcon(name: row.name)
            }
        } else {
            fallbackIcon(name: row.name)
        }
    }

    private func fallbackIcon(name: String) -> some View {
        let first = String(name.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: entrySize.cornerRadius)
                .fill(Color.secondary.opacity(0.10))
            Text(first.isEmpty ? "?" : first)
                .font(.system(size: entrySize.icon * 0.45, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func visibilityAction(for row: DashboardAppRow) -> some View {
        if visibility.isHidden(row) {
            Button { setHidden(false, for: row) } label: {
                Label(L10n.tr("Im Dashboard einblenden"), systemImage: "eye")
            }
        } else {
            Button { setHidden(true, for: row) } label: {
                Label(L10n.tr("Im Dashboard ausblenden"), systemImage: "eye.slash")
            }
        }
    }

    private func setHidden(_ hidden: Bool, for row: DashboardAppRow) {
        do {
            try visibility.setHidden(hidden, for: row)
            if hidden { lastHiddenApp = row }
            else if lastHiddenApp?.id == row.id { lastHiddenApp = nil }
        } catch {
            visibilityError = error.localizedDescription
        }
    }

    private func selectRow(_ row: DashboardAppRow) {
        if let links = row.projectLinks, links.count == 1, let link = links.first {
            selectLinkedTarget(link)
        } else if row.projectLinks == nil, let projectId = row.linkedProjectId {
            // Linked local project — open it as before.
            appState.activeTab = .app
            appState.activeAppSubTab = .overview
            appState.activeProjectId = projectId
            let id = projectId
            Task.detached(priority: .utility) {
                ProjectStorage().updateLastOpened(projectId: id)
            }
        } else if let bundleId = row.bundleId {
            // ASC-only app — stay in this window, focus the ASC manager on this bundle id,
            // and route the user to the App > Overview tab so the synthesized dashboard renders.
            appState.activeProjectId = nil
            appState.activeTab = .app
            appState.activeAppSubTab = .overview
            Task {
                await appState.ascManager.loadCredentials(for: "asc:\(bundleId)", bundleId: bundleId)
                await appState.ascManager.ensureTabData(.app)
            }
        }
    }

    private func selectLinkedTarget(_ link: DashboardProjectLink) {
        Task {
            do {
                try await appState.projectManager.selectReleaseTarget(projectId: link.projectId, targetId: link.targetId)
                appState.activeProjectId = link.projectId
                appState.activeTab = .app
                appState.activeAppSubTab = .overview
                let bundle = appState.activeProject?.metadata.bundleIdentifier
                appState.ascManager.prepareForProjectSwitch(to: link.projectId, bundleId: bundle)
                await appState.ascManager.loadCredentials(for: link.projectId, bundleId: bundle)
                await appState.ascManager.ensureTabData(.app)
            } catch { visibilityError = error.localizedDescription }
        }
    }

    private func hydrateSummary(force: Bool = false) async {
        let hydrationKey = summaryHydrationKey
        // Make sure credentials are loaded up front — even if there is no active project,
        // the dashboard should show the user's ASC apps as soon as possible.
        appState.ascManager.loadStoredCredentialsIfNeeded()
        let accountKey = DashboardSummaryStore.accountKey(for: appState.ascManager.credentials)
        guard let service = appState.ascManager.service else {
            if force { dashboardSummary.refreshIcons(for: projects) }
            dashboardSummary.markUnavailable(for: hydrationKey, accountKey: accountKey, issue: .missingCredentials)
            return
        }

        await dashboardSummary.refresh(
            for: hydrationKey,
            accountKey: accountKey,
            service: service,
            projects: appState.projectManager.projects,
            force: force
        )
    }

    private func forceRefreshApps() {
        Task { await hydrateSummary(force: true) }
    }

    // MARK: - Helpers

    private func statValue(_ count: Int) -> String {
        dashboardSummary.hasLoadedSummary ? "\(count)" : "—"
    }

}
