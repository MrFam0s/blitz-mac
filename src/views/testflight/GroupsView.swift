import SwiftUI

struct GroupsView: View {
    var appState: AppState
    private var asc: ASCManager { appState.ascManager }
    private var selection: Binding<String?> {
        Binding(get: { asc.selectedTestFlightGroupId }, set: { asc.selectedTestFlightGroupId = $0 })
    }

    var body: some View {
        ASCCredentialGate(appState: appState, ascManager: asc,
                          projectId: appState.activeProjectId ?? "",
                          bundleId: appState.activeProject?.metadata.bundleIdentifier) {
            ASCTabContent(appState: appState, asc: asc, tab: .groups,
                          platform: appState.activeProject?.platform ?? .iOS, allowWithoutLocalProject: true) {
                groupsContent
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            await asc.ensureTabData(.groups)
        }
        .onAppear { syncSelection() }
        .onChange(of: asc.betaGroups.map(\.id)) { _, _ in syncSelection() }
    }

    private var groupsContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("Testgruppen")).font(BlitzLayout.pageTitle)
                Spacer()
                TestFlightRefreshButton(isRefreshing: isRefreshing, action: refresh)
                    .help(L10n.tr("Gruppen und ausgewählte Gruppendetails aktualisieren"))
            }.blitzToolbar()
            Divider()
            if asc.betaGroups.isEmpty {
                if asc.isTabLoading(.groups) {
                    ASCTabLoadingPlaceholder(title: L10n.tr("Testgruppen werden geladen"), message: L10n.tr("Interne und externe TestFlight-Gruppen werden geladen."))
                } else {
                    ContentUnavailableView(L10n.tr("Keine Testgruppen"), systemImage: "person.3",
                                           description: Text(L10n.tr("Für diese App wurden keine Testgruppen gefunden.")))
                }
            } else {
                GeometryReader { geometry in
                    if geometry.size.width < 760 {
                        VStack(spacing: 0) {
                            Picker(L10n.tr("Gruppe"), selection: selection) {
                                ForEach(asc.betaGroups) { group in
                                    Text("\(group.attributes.name) · \(TestFlightPresentation.groupType(group))")
                                        .tag(Optional(group.id))
                                }
                            }.pickerStyle(.menu).controlSize(.small)
                                .frame(maxWidth: .infinity, alignment: .leading).blitzPagePadding()
                            Divider()
                            selectedGroupDetail
                        }
                    } else {
                        HStack(spacing: 0) {
                            List(selection: selection) {
                                ForEach(asc.betaGroups) { group in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.attributes.name).font(.callout.weight(.medium))
                                        Text(TestFlightPresentation.groupType(group)).font(.caption).foregroundStyle(.secondary)
                                    }.fixedSize(horizontal: false, vertical: true)
                                        .padding(.vertical, 4).tag(group.id)
                                }
                            }.listStyle(.inset).frame(width: 260)
                            Divider()
                            selectedGroupDetail
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var selectedGroupDetail: some View {
        if let id = asc.selectedTestFlightGroupId,
           let group = asc.betaGroups.first(where: { $0.id == id }) {
            groupDetail(group).frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: "\(asc.app?.id ?? ""):\(asc.projectRevision):\(id)") {
                    await asc.refreshTestFlightGroupDetail(groupId: id, force: false)
                }
        } else {
            ContentUnavailableView(L10n.tr("Gruppe auswählen"), systemImage: "person.3")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func groupDetail(_ listedGroup: ASCBetaGroup) -> some View {
        let detail = asc.testFlightGroupDetails[listedGroup.id]
        let group = listedGroup
        let loading = asc.loadingTestFlightGroupIds.contains(group.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                Text(group.attributes.name).font(BlitzLayout.pageTitle)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    InfoRow(label: L10n.tr("Gruppentyp"), value: TestFlightPresentation.groupType(group))
                    Divider()
                    InfoRow(label: L10n.tr("Zugriff auf alle Builds"), value: booleanLabel(group.attributes.hasAccessToAllBuilds))
                    Divider()
                    InfoRow(label: L10n.tr("Öffentlicher Link"), value: booleanLabel(group.attributes.publicLinkEnabled))
                    Divider()
                    InfoRow(label: L10n.tr("Rückmeldungen"), value: booleanLabel(group.attributes.feedbackEnabled))
                    Divider()
                    InfoRow(label: L10n.tr("Gruppen-ID"), value: group.id)
                }
                HStack {
                    Text(L10n.tr("Gruppendetails")).font(BlitzLayout.sectionTitle)
                    Spacer()
                    TestFlightRefreshButton(isRefreshing: isRefreshing, action: refresh)
                        .help(L10n.tr("Builds und Tester der Gruppe aktualisieren"))
                }
                TestFlightDetailStatus(isLoading: loading, error: asc.testFlightGroupErrors[group.id], hasData: detail != nil) {
                    refresh()
                }
                if let detail {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("Zugeordnete Builds (\(detail.builds.count))")).font(.headline)
                        if detail.builds.isEmpty {
                            Text(L10n.tr("Dieser Gruppe sind keine Builds zugeordnet.")).foregroundStyle(.secondary)
                        } else {
                            ForEach(detail.builds) { build in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(TestFlightPresentation.buildLabel(build)).font(.callout.weight(.medium))
                                    Text(L10n.tr("Verarbeitung: \(TestFlightPresentation.status(build.attributes.processingState)) · \(TestFlightPresentation.expiration(build))"))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(L10n.tr("Intern: \(TestFlightPresentation.status(build.buildBetaDetail?.attributes.internalBuildState)) · Extern: \(TestFlightPresentation.status(build.buildBetaDetail?.attributes.externalBuildState))"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("Tester der Gruppe (\(detail.testers.count))")).font(.headline)
                        Text(L10n.tr("Die Mitgliedschaft in einer Gruppe bestätigt nicht, dass ein Tester einen zugeordneten Build installiert hat."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if detail.testers.isEmpty {
                            Text(L10n.tr("Diese Gruppe hat keine Tester.")).foregroundStyle(.secondary)
                        } else {
                            ForEach(detail.testers) { TestFlightTesterRow(tester: $0) }
                        }
                    }
                }
                if let appId = asc.app?.id,
                   let url = URL(string: "https://appstoreconnect.apple.com/apps/\(appId)/testflight/groups") {
                    Link(L10n.tr("Gruppen in App Store Connect öffnen"), destination: url).font(.callout)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).blitzPagePadding()
        }
    }

    private func booleanLabel(_ value: Bool?) -> String {
        switch value {
        case true: L10n.tr("Aktiviert")
        case false: L10n.tr("Deaktiviert")
        default: L10n.tr("Nicht verfügbar")
        }
    }

    private func syncSelection() {
        if !asc.betaGroups.contains(where: { $0.id == asc.selectedTestFlightGroupId }) {
            asc.selectedTestFlightGroupId = asc.betaGroups.first?.id
        }
    }

    private var isRefreshing: Bool {
        asc.isTabLoading(.groups) || asc.selectedTestFlightGroupId.map { asc.loadingTestFlightGroupIds.contains($0) } == true
    }

    private func refresh() {
        let revision = asc.projectRevision
        let appId = asc.app?.id
        let groupId = asc.selectedTestFlightGroupId
        Task {
            await asc.refreshTabData(.groups)
            guard asc.projectRevision == revision, asc.app?.id == appId, !Task.isCancelled,
                  asc.tabError[.groups] == nil, asc.selectedTestFlightGroupId == groupId,
                  let groupId, asc.betaGroups.contains(where: { $0.id == groupId }) else { return }
            await asc.refreshTestFlightGroupDetail(groupId: groupId)
        }
    }
}
