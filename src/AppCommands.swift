// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

struct AppCommands: Commands {
    let appState: AppState

    var body: some Commands {
        // Replace File menu contents with Project items
        CommandGroup(replacing: .newItem) {
            Button(L10n.tr("Neues Projekt …")) {
                appState.showNewProjectSheet = true
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(L10n.tr("Projekt öffnen …")) {
                openProjectFromMenu()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button(L10n.tr("Projekt importieren …")) {
                appState.showImportProjectSheet = true
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Divider()

            // Open Recent submenu
            Menu(L10n.tr("Zuletzt geöffnet")) {
                let sorted = appState.projectManager.projects.sorted {
                    ($0.metadata.lastOpenedAt ?? .distantPast) > ($1.metadata.lastOpenedAt ?? .distantPast)
                }

                if sorted.isEmpty {
                    Text(L10n.tr("Keine zuletzt geöffneten Projekte"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sorted) { project in
                        Button {
                            let storage = ProjectStorage()
                            storage.updateLastOpened(projectId: project.id)
                            appState.activeProjectId = project.id
                        } label: {
                            Label(project.name, systemImage: projectIcon(project))
                        }
                    }

                    Divider()

                    Button(L10n.tr("Liste leeren")) {
                        let storage = ProjectStorage()
                        storage.clearRecentProjects()
                        Task {
                            await appState.projectManager.loadProjects()
                        }
                    }
                }
            }

            Divider()

            Button(L10n.tr("Projekt schließen")) {
                appState.activeProjectId = nil
                appState.activeTab = .dashboard
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(appState.activeProjectId == nil)
        }

        // View menu additions
        CommandGroup(after: .toolbar) {
            Divider()

            Button("Dashboard") {
                appState.activeTab = .dashboard
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Simulator") {
                appState.activeTab = .app
                appState.activeAppSubTab = .simulator
            }
            .keyboardShortcut("2", modifiers: .command)
        }

        // View > Terminal toggle
        CommandGroup(after: .sidebar) {
            Button(appState.showTerminal ? L10n.tr("Terminal ausblenden") : L10n.tr("Terminal einblenden")) {
                appState.showTerminal.toggle()
                if appState.showTerminal && appState.terminalManager.sessions.isEmpty {
                    appState.terminalManager.createSession(projectPath: appState.activeProject?.path)
                }
            }
            .keyboardShortcut("`", modifiers: .command)
        }

        // Build menu
        CommandMenu("Build") {
            Button(L10n.tr("Starten")) {
                guard appState.activeProject != nil else { return }
                Task {
                    await appState.startProjectSimulator()
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(appState.activeProjectId == nil)

            Button(L10n.tr("Stoppen")) {
                Task { await appState.stopProjectSimulator() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!appState.simulatorStream.isCapturing && !appState.simulatorManager.isBooting)
        }
    }

    private func openProjectFromMenu() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.tr("Wähle einen Blitz-Neo-Projektordner aus.")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let storage = ProjectStorage()
        do {
            let projectId = try storage.openProject(at: url)
            Task {
                await appState.projectManager.loadProjects()
                appState.activeProjectId = projectId
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.tr("Projekt konnte nicht geöffnet werden")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func projectIcon(_ project: Project) -> String {
        if project.platform == .macOS { return "desktopcomputer" }
        switch project.type {
        case .reactNative: return "atom"
        case .swift: return "swift"
        case .flutter: return "bird"
        }
    }
}
