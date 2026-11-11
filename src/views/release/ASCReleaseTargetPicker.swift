import SwiftUI

/// One selection drives listing, builds, media and release actions. Choosing a
/// local target persists only local metadata; no Apple version is created here.
struct ASCReleaseTargetPicker: View {
    var asc: ASCManager
    var tab: AppTab
    @State private var showSetup = false
    @State private var setupTargetId: String?
    @State private var selectionError: String?
    @State private var switching = false

    private var project: Project? { asc.appState?.activeProject }
    private var linkedProjects: [Project] {
        guard let app = asc.app, let state = asc.appState else { return [] }
        return state.projectManager.projects.filter { project in
            project.releaseTargets.contains { target in
                target.bundleIdentifier == app.bundleId && (target.storeBinding == nil ||
                    (target.storeBinding?.appId == app.id && target.storeBinding?.accountKey ==
                        DashboardSummaryStore.accountKey(for: asc.credentials)))
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Menu {
            if let project {
                ForEach(project.releaseTargets) { target in
                    Button(target.displayName + " · " + target.platform.rawValue) {
                        select(projectId: project.id, targetId: target.id)
                    }
                }
            } else {
                ForEach(ProjectPlatform.allCases, id: \.self) { platform in
                    Button(platform.rawValue) {
                        asc.selectReleasePlatform(platform)
                        Task { await asc.refreshTabData(tab) }
                    }
                }
            }
            ForEach(linkedProjects.filter { $0.id != project?.id }) { linked in
                Section(linked.name) {
                    ForEach(linked.releaseTargets.filter { $0.bundleIdentifier == asc.app?.bundleId }) { target in
                        Button(target.displayName + " · " + target.platform.rawValue) {
                            select(projectId: linked.id, targetId: target.id)
                        }
                    }
                }
            }
            if project != nil {
                Divider()
                if let target = project?.selectedReleaseTarget {
                    Button("Store-Zuordnung prüfen / verknüpfen …") {
                        setupTargetId = target.id; showSetup = true
                    }
                }
                Button("Veröffentlichungsziel hinzufügen …") { setupTargetId = nil; showSetup = true }
            }
        } label: {
            Label(project?.selectedReleaseTarget?.displayName ?? asc.releasePlatform?.rawValue ?? "Plattform wählen",
                  systemImage: asc.releasePlatform == .macOS ? "desktopcomputer" : "iphone")
                .lineLimit(1)
        }
        .controlSize(.small)
        .disabled(switching || asc.isCreatingVersion || asc.isSubmitting || asc.isSyncing)
        .help("Veröffentlichungsziel und Plattform")
        .sheet(isPresented: $showSetup) {
            if let state = asc.appState {
                ProjectReleaseTargetSetupView(appState: state, releaseTargetId: setupTargetId, onSaved: {
                    showSetup = false
                    Task { await reloadSelectedTarget(state: state) }
                })
            }
        }
        .alert("Veröffentlichungsziel", isPresented: Binding(get: { selectionError != nil },
            set: { if !$0 { selectionError = nil } })) {
            Button("OK") { selectionError = nil }
        } message: { Text(selectionError ?? "") }
    }

    private func select(projectId: String, targetId: String) {
        guard let state = asc.appState else { return }
        switching = true
        Task {
            defer { switching = false }
            do {
                try await state.projectManager.selectReleaseTarget(projectId: projectId, targetId: targetId)
                state.activeProjectId = projectId
                await reloadSelectedTarget(state: state)
            } catch { selectionError = error.localizedDescription }
        }
    }

    private func reloadSelectedTarget(state: AppState) async {
        guard let project = state.activeProject else { return }
        asc.prepareForProjectSwitch(to: project.id, bundleId: project.metadata.bundleIdentifier, force: true)
        await asc.loadCredentials(for: project.id, bundleId: project.metadata.bundleIdentifier)
        await asc.ensureTabData(tab)
    }
}
