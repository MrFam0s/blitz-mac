// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

struct NewProjectSheet: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    @State private var projectName = ""
    @State private var platform: ProjectPlatform = .iOS
    @State private var projectType: ProjectType = .swift
    @State private var errorMessage: String?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
            BlitzSetupHeader(L10n.tr("Neues Projekt"), subtitle: L10n.tr("Erstelle ein lokales App-Projekt. Den Eintrag in App Store Connect richtest du anschließend separat ein."))

            Divider()

            VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                BlitzSetupField(L10n.tr("Projektname"), hint: L10n.tr("Der öffentliche App-Store-Name wird später festgelegt.")) {
                    TextField(L10n.tr("z. B. MeineApp"), text: $projectName)
                        .accessibilityLabel(L10n.tr("Projektname"))
                }
                BlitzSetupField(L10n.tr("Plattform")) {
                    Picker(L10n.tr("Plattform"), selection: $platform) {
                        Text("iOS").tag(ProjectPlatform.iOS)
                        Text("macOS").tag(ProjectPlatform.macOS)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(L10n.tr("Plattform"))
                    .onChange(of: platform) { _, newPlatform in
                        // macOS only supports Swift for now
                        if newPlatform == .macOS {
                            projectType = .swift
                        }
                    }
                }
                BlitzSetupField(L10n.tr("Projekttyp")) {
                    Picker(L10n.tr("Projekttyp"), selection: $projectType) {
                        if platform == .iOS {
                            Text("React Native").tag(ProjectType.reactNative)
                            Text("Swift").tag(ProjectType.swift)
                        } else {
                            Text("Swift").tag(ProjectType.swift)
                        }
                    }
                    .accessibilityLabel(L10n.tr("Projekttyp"))
                }
            }
            .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: BlitzLayout.fieldSpacing) {
                Button(L10n.tr("Abbrechen")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isCreating { ProgressView().controlSize(.small) }
                Button(L10n.tr("Projekt anlegen")) {
                    Task { await createProject() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || (try? ProjectCreationReservation.projectID(for: projectName)) == nil)
            }
        }
        .font(.callout)
        .padding(24)
        .frame(width: 560)
    }

    private func createProject() async {
        guard !isCreating else { return }
        guard !appState.projectSetup.isSettingUp else {
            errorMessage = L10n.tr("Ein anderes Projekt wird gerade angelegt. Warte, bis der Vorgang abgeschlossen ist.")
            return
        }
        isCreating = true
        defer { isCreating = false }
        errorMessage = nil

        let storage = ProjectStorage()
        let metadata = BlitzProjectMetadata(
            name: projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            type: projectType,
            platform: platform,
            createdAt: Date(),
            lastOpenedAt: Date()
        )

        let projectId: String
        do {
            projectId = try storage.createProject(metadata: metadata)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        AnalyticsService.trackProjectCreate(projectType: projectType)

        // Reload project list so the new project appears in the switcher
        await appState.projectManager.loadProjects()

        // Flag that this project needs setup — ContentView will trigger it
        appState.projectSetup.pendingSetupProjectId = projectId

        // Clear the sheet flag before switching projects — showNewProjectSheet is on
        // shared appState, so if it stays true the main window's .sheet binding fires too.
        appState.showNewProjectSheet = false

        // Open on App > Overview tab, then select the new project.
        appState.activeTab = .app
        appState.activeAppSubTab = .overview
        appState.activeProjectId = projectId
    }
}
