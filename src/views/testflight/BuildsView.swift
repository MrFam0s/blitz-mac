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
        .onChange(of: asc.releasePlatformBuilds.map(\.id)) { _, _ in syncSelection() }
    }

    private var buildsContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Builds").font(BlitzLayout.pageTitle)
                Spacer()
                TestFlightRefreshButton(isRefreshing: isRefreshing, action: refresh)
                    .help("Builds und ausgewählte Verteilungsdetails aktualisieren")
            }.blitzToolbar()
            Divider()
            if asc.releasePlatformBuilds.isEmpty {
                if asc.isTabLoading(.builds) {
                    ASCTabLoadingPlaceholder(title: "Builds werden geladen", message: "Metadaten der TestFlight-Builds werden geladen.")
                } else {
                    ContentUnavailableView("Keine Builds", systemImage: "hammer",
                                           description: Text("Für diese App wurden keine TestFlight-Builds gefunden."))
                }
            } else {
                GeometryReader { geometry in
                    if geometry.size.width < 760 {
                        VStack(spacing: 0) {
                            Picker("Build", selection: selection) {
                                ForEach(asc.releasePlatformBuilds) { build in
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
                                ForEach(asc.releasePlatformBuilds) { build in buildRow(build).tag(build.id) }
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
           let build = asc.releasePlatformBuilds.first(where: { $0.id == id }) {
            buildDetail(build)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: "\(asc.app?.id ?? ""):\(asc.projectRevision):\(id)") {
                    await asc.refreshTestFlightBuildDetail(buildId: id, force: false)
                }
        } else {
            ContentUnavailableView("Build auswählen", systemImage: "hammer")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func buildRow(_ build: ASCBuild) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(TestFlightPresentation.buildLabel(build))
                .font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Text("Verarbeitung: \(TestFlightPresentation.status(build.attributes.processingState))")
                .font(.caption).foregroundStyle(.secondary)
            if let date = build.attributes.uploadedDate {
                Text(ascShortDate(date)).font(.caption).foregroundStyle(.secondary)
            }
            if TestFlightPresentation.expiration(build) == "Abgelaufen" {
                Text("Abgelaufen").font(.caption).foregroundStyle(.red)
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
                    InfoRow(label: "Versionsnummer", value: build.preReleaseVersion?.attributes.version ?? "Nicht verfügbar")
                    Divider()
                    InfoRow(label: "Buildnummer", value: build.attributes.version)
                    Divider()
                    InfoRow(label: "Plattform", value: TestFlightPresentation.platform(build.preReleaseVersion?.attributes.platform))
                    Divider()
                    InfoRow(label: "Verarbeitung", value: TestFlightPresentation.status(build.attributes.processingState))
                    Divider()
                    InfoRow(label: "Interner Test", value: TestFlightPresentation.status(build.buildBetaDetail?.attributes.internalBuildState))
                    Divider()
                    InfoRow(label: "Externer Test", value: TestFlightPresentation.status(build.buildBetaDetail?.attributes.externalBuildState))
                    Divider()
                    InfoRow(label: "Gültigkeit", value: TestFlightPresentation.expiration(build))
                    if let expiry = build.attributes.expirationDate {
                        Divider()
                        InfoRow(label: "Gültig bis", value: ascLongDate(expiry))
                    }
                    if let date = build.attributes.uploadedDate {
                        Divider()
                        InfoRow(label: "Hochgeladen", value: ascLongDate(date))
                    }
                    if let minOS = build.attributes.minOsVersion {
                        Divider()
                        InfoRow(label: "Mindestens benötigte OS-Version", value: minOS)
                    }
                    Divider()
                    InfoRow(label: "Build-ID", value: build.id)
                }
                HStack {
                    Text("Verteilung").font(BlitzLayout.sectionTitle)
                    Spacer()
                    TestFlightRefreshButton(isRefreshing: isRefreshing, action: refresh)
                        .help("Builddetails und Verteilung aktualisieren")
                }
                TestFlightDetailStatus(isLoading: loading, error: asc.testFlightBuildErrors[build.id], hasData: detail != nil) {
                    refresh()
                }
                if let detail {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Zugeordnete Gruppen (\(detail.betaGroups.count))").font(.headline)
                        if detail.betaGroups.isEmpty {
                            Text("Diesem Build sind keine Gruppen zugeordnet.").foregroundStyle(.secondary)
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
                        Text("Einzeln zugeordnete Tester (\(detail.individualTesters.count))").font(.headline)
                        Text("Nur direkte Zuordnungen. Tester, die den Build über eine Gruppe erhalten, stehen in den Details dieser Gruppe.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if detail.individualTesters.isEmpty {
                            Text("Es sind keine einzelnen Tester zugeordnet.").foregroundStyle(.secondary)
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
        if !asc.releasePlatformBuilds.contains(where: { $0.id == asc.selectedTestFlightBuildId }) {
            asc.selectedTestFlightBuildId = asc.releasePlatformBuilds.first?.id
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
                  let buildId, asc.releasePlatformBuilds.contains(where: { $0.id == buildId }) else { return }
            await asc.refreshTestFlightBuildDetail(buildId: buildId)
        }
    }
}
