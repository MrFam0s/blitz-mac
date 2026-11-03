import SwiftUI

struct BuildsView: View {
    var appState: AppState
    private var asc: ASCManager { appState.ascManager }
    private var selection: Binding<String?> {
        Binding(get: { asc.selectedTestFlightBuildId }, set: { asc.selectedTestFlightBuildId = $0 })
    }

    var body: some View {
        ASCCredentialGate(appState: appState, ascManager: asc,
                          projectId: appState.activeProjectId ?? "",
                          bundleId: appState.activeProject?.metadata.bundleIdentifier) {
            ASCTabContent(appState: appState, asc: asc, tab: .builds,
                          platform: appState.activeProject?.platform ?? .iOS, allowWithoutLocalProject: true) {
                buildsContent
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            await asc.ensureTabData(.builds)
        }
        .onAppear { syncSelection() }
        .onChange(of: asc.builds.map(\.id)) { _, _ in syncSelection() }
    }

    private var buildsContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Builds").font(BlitzLayout.pageTitle)
                Spacer()
                TestFlightRefreshButton(isRefreshing: isRefreshing, action: refresh)
                    .help("Refresh builds and selected distribution details")
            }.blitzToolbar()
            Divider()
            if asc.builds.isEmpty {
                if asc.isTabLoading(.builds) {
                    ASCTabLoadingPlaceholder(title: "Loading Builds", message: "Fetching TestFlight build metadata.")
                } else {
                    ContentUnavailableView("No Builds", systemImage: "hammer",
                                           description: Text("No TestFlight builds found for this app."))
                }
            } else {
                GeometryReader { geometry in
                    if geometry.size.width < 760 {
                        VStack(spacing: 0) {
                            Picker("Build", selection: selection) {
                                ForEach(asc.builds) { build in
                                    Text(TestFlightPresentation.buildLabel(build)).tag(Optional(build.id))
                                }
                            }
                            .pickerStyle(.menu).controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading).blitzPagePadding()
                            Divider()
                            selectedBuildDetail
                        }
                    } else {
                        HStack(spacing: 0) {
                            List(selection: selection) {
                                ForEach(asc.builds) { build in buildRow(build).tag(build.id) }
                            }.listStyle(.inset).frame(width: 280)
                            Divider()
                            selectedBuildDetail
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var selectedBuildDetail: some View {
        if let id = asc.selectedTestFlightBuildId,
           let build = asc.builds.first(where: { $0.id == id }) {
            buildDetail(build)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: "\(asc.app?.id ?? ""):\(asc.projectRevision):\(id)") {
                    await asc.refreshTestFlightBuildDetail(buildId: id, force: false)
                }
        } else {
            ContentUnavailableView("Select a Build", systemImage: "hammer")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func buildRow(_ build: ASCBuild) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(TestFlightPresentation.buildLabel(build))
                .font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Text("Processing: \(TestFlightPresentation.status(build.attributes.processingState))")
                .font(.caption).foregroundStyle(.secondary)
            if let date = build.attributes.uploadedDate {
                Text(ascShortDate(date)).font(.caption).foregroundStyle(.secondary)
            }
            if TestFlightPresentation.expiration(build) == "Expired" {
                Text("Expired").font(.caption).foregroundStyle(.red)
            }
        }.padding(.vertical, 4)
    }

    private func buildDetail(_ listedBuild: ASCBuild) -> some View {
        let detail = asc.testFlightBuildDetails[listedBuild.id]
        let build = listedBuild
        let loading = asc.loadingTestFlightBuildIds.contains(build.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                Text(TestFlightPresentation.buildLabel(build))
                    .font(BlitzLayout.pageTitle).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    InfoRow(label: "Marketing Version", value: build.preReleaseVersion?.attributes.version ?? "Not available")
                    Divider()
                    InfoRow(label: "Build Number", value: build.attributes.version)
                    Divider()
                    InfoRow(label: "Platform", value: TestFlightPresentation.platform(build.preReleaseVersion?.attributes.platform))
                    Divider()
                    InfoRow(label: "Processing", value: TestFlightPresentation.status(build.attributes.processingState))
                    Divider()
                    InfoRow(label: "Internal Testing", value: TestFlightPresentation.status(build.buildBetaDetail?.attributes.internalBuildState))
                    Divider()
                    InfoRow(label: "External Testing", value: TestFlightPresentation.status(build.buildBetaDetail?.attributes.externalBuildState))
                    Divider()
                    InfoRow(label: "Expiry", value: TestFlightPresentation.expiration(build))
                    if let expiry = build.attributes.expirationDate {
                        Divider()
                        InfoRow(label: "Expires", value: ascLongDate(expiry))
                    }
                    if let date = build.attributes.uploadedDate {
                        Divider()
                        InfoRow(label: "Uploaded", value: ascLongDate(date))
                    }
                    if let minOS = build.attributes.minOsVersion {
                        Divider()
                        InfoRow(label: "Minimum OS", value: minOS)
                    }
                    Divider()
                    InfoRow(label: "Build ID", value: build.id)
                }
                HStack {
                    Text("Distribution").font(BlitzLayout.sectionTitle)
                    Spacer()
                    TestFlightRefreshButton(isRefreshing: isRefreshing, action: refresh)
                        .help("Refresh build details and distribution")
                }
                TestFlightDetailStatus(isLoading: loading, error: asc.testFlightBuildErrors[build.id], hasData: detail != nil) {
                    refresh()
                }
                if let detail {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Assigned Groups (\(detail.betaGroups.count))").font(.headline)
                        if detail.betaGroups.isEmpty {
                            Text("No groups are assigned to this build.").foregroundStyle(.secondary)
                        } else {
                            ForEach(detail.betaGroups) { group in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.attributes.name).font(.callout.weight(.medium))
                                    Text(TestFlightPresentation.groupType(group)).font(.caption).foregroundStyle(.secondary)
                                }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Individual Testers (\(detail.individualTesters.count))").font(.headline)
                        Text("Direct assignments only. Testers who receive the build through a group are listed in that group's details.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if detail.individualTesters.isEmpty {
                            Text("No individual testers are assigned.").foregroundStyle(.secondary)
                        } else {
                            ForEach(detail.individualTesters) { TestFlightTesterRow(tester: $0) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).blitzPagePadding()
        }
    }

    private func syncSelection() {
        if !asc.builds.contains(where: { $0.id == asc.selectedTestFlightBuildId }) {
            asc.selectedTestFlightBuildId = asc.builds.first?.id
        }
    }

    private var isRefreshing: Bool {
        asc.isTabLoading(.builds) || asc.selectedTestFlightBuildId.map { asc.loadingTestFlightBuildIds.contains($0) } == true
    }

    private func refresh() {
        let revision = asc.projectRevision
        let appId = asc.app?.id
        let buildId = asc.selectedTestFlightBuildId
        Task {
            await asc.refreshTabData(.builds)
            guard asc.projectRevision == revision, asc.app?.id == appId, !Task.isCancelled,
                  asc.tabError[.builds] == nil, asc.selectedTestFlightBuildId == buildId,
                  let buildId, asc.builds.contains(where: { $0.id == buildId }) else { return }
            await asc.refreshTestFlightBuildDetail(buildId: buildId)
        }
    }
}
