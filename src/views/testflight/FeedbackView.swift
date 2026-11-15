import SwiftUI

struct FeedbackView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    @State private var localSelectedBuildId: String = ""

    var body: some View {
        ASCCredentialGate(
            appState: appState,
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(appState: appState, asc: asc, tab: .feedback, platform: appState.activeProject?.platform ?? .iOS, allowWithoutLocalProject: true) {
                feedbackContent
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            await asc.ensureTabData(.feedback)
        }
    }

    @ViewBuilder
    private var feedbackContent: some View {
        let builds = asc.releasePlatformBuilds
        let effectiveBuildId = resolvedBuildId(from: builds)
        let feedback = asc.betaFeedback[effectiveBuildId] ?? []
        let isLoadingFeedback = asc.isFeedbackLoading(for: effectiveBuildId)

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Rückmeldungen")
                        .font(BlitzLayout.pageTitle)
                    Spacer()
                    if isLoadingFeedback {
                        ProgressView()
                            .controlSize(.small)
                    }
                    ASCTabRefreshButton(asc: asc, tab: .feedback, helpText: "Rückmeldungen aktualisieren")
                }

                if !builds.isEmpty {
                    Picker("Build", selection: $localSelectedBuildId) {
                        ForEach(builds) { build in
                            Text(TestFlightPresentation.buildLabel(build))
                                .tag(build.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Build")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        if localSelectedBuildId.isEmpty {
                            localSelectedBuildId = asc.selectedBuildId ?? builds.first?.id ?? ""
                        }
                    }
                }
            }
            .blitzToolbar()

            Divider()

            if builds.isEmpty {
                if asc.isTabLoading(.feedback) {
                    ASCTabLoadingPlaceholder(
                        title: "Rückmeldungen werden geladen",
                        message: "Builds und aktuelle Rückmeldungen der Tester werden geladen."
                    )
                } else {
                    ContentUnavailableView(
                        "Keine Builds",
                        systemImage: "hammer",
                        description: Text("Lade einen TestFlight-Build hoch, um Rückmeldungen von Testern zu erhalten.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if feedback.isEmpty {
                if isLoadingFeedback {
                    ASCTabLoadingPlaceholder(
                        title: "Rückmeldungen werden geladen",
                        message: "Kommentare und Screenshots der Tester zu diesem Build werden geladen."
                    )
                } else if let error = asc.tabError[.feedback] {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Rückmeldungen konnten nicht geladen werden", systemImage: "exclamationmark.triangle")
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Erneut versuchen") {
                            Task { await asc.refreshBetaFeedback(buildId: effectiveBuildId) }
                        }.buttonStyle(.bordered)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).blitzPagePadding()
                } else if asc.betaFeedback[effectiveBuildId] == nil {
                    ASCTabLoadingPlaceholder(title: "Rückmeldungen werden geladen", message: "Kommentare und Screenshots der Tester zu diesem Build werden geladen.")
                } else {
                    ContentUnavailableView(
                        "Keine Rückmeldungen",
                        systemImage: "exclamationmark.bubble",
                        description: Text("Für diesen Build gibt es noch keine Rückmeldungen von Testern.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(feedback) { item in
                    feedbackRow(item)
                        .listRowInsets(EdgeInsets(top: 12, leading: BlitzLayout.pageInset, bottom: 12, trailing: BlitzLayout.pageInset))
                }
                .listStyle(.plain)
            }
        }
        .onChange(of: localSelectedBuildId) { _, newValue in
            guard !newValue.isEmpty else { return }
            asc.selectedBuildId = newValue
            Task { await asc.refreshBetaFeedback(buildId: newValue, force: false) }
        }
        .onAppear {
            syncSelectedBuild(with: builds)
        }
        .onChange(of: builds.map(\.id)) { _, _ in
            syncSelectedBuild(with: builds)
        }
    }

    private func feedbackRow(_ item: ASCBetaFeedback) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BlitzFlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
                Label(item.attributes.emailAddress ?? "Anonym", systemImage: "person.circle")
                    .font(BlitzLayout.bodyFont.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let ts = item.attributes.timestamp {
                    Text(ascShortDate(ts))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let device = item.attributes.deviceModel {
                BlitzFlowLayout(horizontalSpacing: 8, verticalSpacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(device)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let os = item.attributes.osVersion {
                        Text("OS \(os)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let arch = item.attributes.architecture {
                        Text(arch)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let comment = item.attributes.comment, !comment.isEmpty {
                Text(comment)
                    .font(BlitzLayout.bodyFont)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let screenshotUrl = item.attributes.screenshotUrl,
               let url = URL(string: screenshotUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    case .failure:
                        EmptyView()
                    default:
                        ProgressView().frame(height: 60)
                    }
                }
            }
        }
    }

    private func resolvedBuildId(from builds: [ASCBuild]) -> String {
        if !localSelectedBuildId.isEmpty,
           builds.contains(where: { $0.id == localSelectedBuildId }) {
            return localSelectedBuildId
        }
        if let selectedBuildId = asc.selectedBuildId,
           builds.contains(where: { $0.id == selectedBuildId }) {
            return selectedBuildId
        }
        return builds.first?.id ?? ""
    }

    private func syncSelectedBuild(with builds: [ASCBuild]) {
        let effectiveBuildId = resolvedBuildId(from: builds)
        localSelectedBuildId = effectiveBuildId
        asc.selectedBuildId = effectiveBuildId.isEmpty ? nil : effectiveBuildId
    }
}
