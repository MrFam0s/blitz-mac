import SwiftUI

struct DashboardView: View {
    @Bindable var appState: AppState
    @State private var dashboardSummary = DashboardSummaryStore.shared
    @State private var visibility = DashboardVisibilityStore.shared
    @State private var searchText = ""
    @State private var showsHiddenApps = false
    @State private var lastHiddenApp: DashboardAppRow?
    @State private var visibilityError: String?

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
        .alert("Couldn’t update Dashboard", isPresented: Binding(
            get: { visibilityError != nil },
            set: { if !$0 { visibilityError = nil } }
        )) {
            Button("OK", role: .cancel) { visibilityError = nil }
        } message: {
            Text(visibilityError ?? "")
        }
    }

    // MARK: - Top Navbar

    private var topNavbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                dashboardTitle
                searchField.frame(width: 220)
                Spacer(minLength: 8)
                dashboardTools
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    dashboardTitle
                    Spacer(minLength: 8)
                    dashboardTools
                }
                searchField
            }
        }
    }

    private var dashboardTitle: some View {
        Label("My Apps", systemImage: "folder")
            .font(BlitzLayout.pageTitle)
            .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search apps", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search apps by name or bundle ID")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var dashboardTools: some View {
        HStack(spacing: 12) {
            Button {
                showsHiddenApps.toggle()
            } label: {
                Label(showsHiddenApps ? "Back to My Apps" : "Hidden Apps (\(hiddenAppCount))",
                      systemImage: showsHiddenApps ? "square.grid.2x2" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("View and restore apps removed from this dashboard")

            Button {
                forceRefreshApps()
            } label: {
                if isRefreshingApps {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshingApps)
            .help(refreshButtonHelpText)
            .frame(width: 24, height: 28)
        }
        .fixedSize()
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
        appRows.filter { visibility.isHidden($0) == showsHiddenApps && $0.matches(searchText: searchText) }
    }
    private var showsBlockingSummarySpinner: Bool {
        dashboardSummary.isLoadingSummary && !dashboardSummary.hasLoadedSummary
    }
    private var summaryLoadingStatusText: String {
        dashboardSummary.loadingSummaryStatusText ?? "Loading apps…"
    }
    private var isRefreshingApps: Bool {
        dashboardSummary.isLoading(for: summaryHydrationKey)
    }
    private var refreshButtonHelpText: String {
        guard let date = dashboardSummary.refreshedAt else { return "Refresh My Apps" }
        return "Refresh My Apps · Last updated \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var myAppsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                if dashboardSummary.loadIssue != nil || dashboardSummary.isLoadingSummary {
                    dashboardRefreshStatus
                }
                // Compact counts describe visible apps, independent of the search filter.
                if !showsHiddenApps {
                    BlitzFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                        statCard(
                            title: "Live on Store",
                            value: statValue(visibleSummary.liveCount),
                            color: .green,
                            icon: "checkmark.seal.fill"
                        )
                        statCard(
                            title: "Pending Review",
                            value: statValue(visibleSummary.pendingCount),
                            color: .orange,
                            icon: "clock.fill"
                        )
                        statCard(
                            title: "Rejected Apps",
                            value: statValue(visibleSummary.rejectedCount),
                            color: .red,
                            icon: "xmark.seal.fill"
                        )
                    }
                }

                if showsHiddenApps {
                    Text("Hidden apps stay in App Store Connect and on disk. Restore them here whenever you need them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !displayedRows.isEmpty {
                    // App grid — ASC apps first, local-only projects beneath
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12, alignment: .center)],
                        spacing: 16
                    ) {
                        ForEach(displayedRows) { row in
                            appCard(row: row)
                        }
                    }
                } else if !showsBlockingSummarySpinner {
                    emptyStateView
                }

                Spacer(minLength: 0)
            }
            .blitzPagePadding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DottedCanvasBackground(dotColor: .primary.opacity(0.12)))
        .overlay {
            if showsBlockingSummarySpinner {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(summaryLoadingStatusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let lastHiddenApp {
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(lastHiddenApp.name) removed from Dashboard.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Undo") { setHidden(false, for: lastHiddenApp) }
                        Button { self.lastHiddenApp = nil } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }
                }
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    Button {
                        appState.showNewProjectSheet = true
                    } label: {
                        Label("Create App", systemImage: "plus")
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button {
                        appState.showImportProjectSheet = true
                    } label: {
                        Label("Import App", systemImage: "square.and.arrow.down")
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            .blitzToolbar()
        }
        .task(id: summaryHydrationKey) {
            await hydrateSummary()
        }
    }

    private var dashboardRefreshStatus: some View {
        DashboardRefreshStatusView(
            issueTitle: dashboardSummary.loadIssue?.title,
            issueMessage: dashboardSummary.loadIssue?.message,
            needsSettings: dashboardSummary.loadIssue?.needsSettings == true,
            isShowingSavedData: dashboardSummary.isShowingSavedData,
            hasLoadedSummary: dashboardSummary.hasLoadedSummary,
            isLoading: dashboardSummary.isLoadingSummary,
            loadingText: summaryLoadingStatusText,
            refreshedAt: dashboardSummary.refreshedAt,
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
                 ? "No matching apps" : (showsHiddenApps ? "No hidden apps" : "No apps to show"))
                .font(.headline)
            Text(!searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "Try another name or bundle ID."
                 : (showsHiddenApps ? "Apps you remove from the dashboard will appear here."
                    : (hiddenAppCount > 0 ? "Restore an app from Hidden Apps, or import another project."
                       : "Create a new app or import an existing project to get started.")))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Stat Card

    private func statCard(title: String, value: String, color: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    // MARK: - App Card

    @ViewBuilder
    private func appCard(row: DashboardAppRow) -> some View {
        let isSelected = row.linkedProjectId != nil && row.linkedProjectId == appState.activeProjectId
        let project = row.linkedProjectId.flatMap { id in projects.first(where: { $0.id == id }) }

        Button { selectRow(row) } label: {
            appCardContent(row: row, project: project, isSelected: isSelected)
                .frame(maxWidth: .infinity)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(row.name)")
        .contextMenu { visibilityAction(for: row) }
        .help([row.name, row.bundleId].compactMap { $0 }.joined(separator: "\n"))
    }

    private func appCardContent(row: DashboardAppRow, project: Project?, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            Group {
                if let project {
                    ProjectAppIconView(project: project, size: 56, cornerRadius: 12) {
                        ascIcon(for: row)
                    }
                } else {
                    ascIcon(for: row)
                }
            }
            .padding(3)
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .overlay(alignment: .bottomTrailing) {
                if row.status != nil || (row.bundleId.map { dashboardSummary.unavailableStatusBundleIDs.contains($0) } ?? false) {
                    statusIcon(for: row)
                        .font(.system(size: 12))
                        .padding(2)
                        .background(.background, in: Circle())
                        .offset(x: 2, y: 2)
                }
            }

            Text(row.name)
                .font(.callout.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text(row.source == .localOnly ? "Local only" : " ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(row.source != .localOnly)
        }
        .frame(minHeight: 112, alignment: .top)
    }

    @ViewBuilder
    private func ascIcon(for row: DashboardAppRow) -> some View {
        if let iconURL = row.iconURL {
            DashboardRemoteIconView(url: iconURL, refreshRevision: dashboardSummary.iconRefreshRevision) {
                fallbackIcon(name: row.name)
            }
            .frame(width: 56, height: 56)
        } else {
            fallbackIcon(name: row.name)
        }
    }

    private func fallbackIcon(name: String) -> some View {
        let first = String(name.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 56, height: 56)
            Text(first.isEmpty ? "?" : first)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.7))
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func visibilityAction(for row: DashboardAppRow) -> some View {
        if visibility.isHidden(row) {
            Button { setHidden(false, for: row) } label: {
                Label("Restore to Dashboard", systemImage: "eye")
            }
        } else {
            Button { setHidden(true, for: row) } label: {
                Label("Remove from Dashboard", systemImage: "eye.slash")
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
        if let projectId = row.linkedProjectId {
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

    @ViewBuilder
    private func statusIcon(for row: DashboardAppRow) -> some View {
        if let bundle = row.bundleId, dashboardSummary.unavailableStatusBundleIDs.contains(bundle) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
                .help("Status could not be refreshed")
        } else if let status = row.status {
            if status.isRejected {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            } else if status.isPendingReview {
                Image(systemName: "clock.fill")
                    .foregroundStyle(.orange)
            } else if status.isLiveOnStore {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
