import SwiftUI

struct SidebarView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $appState.activeTab) {
                // Top-level standalone tabs
                Section {
                    navigationRow(.dashboard)

                    // App tab — shows dynamic project icon + name
                    HStack(spacing: 8) {
                        if let project = appState.activeProject {
                            ProjectAppIconView(project: project, size: 18, cornerRadius: 4) {
                                Image(systemName: projectIcon(project))
                                    .foregroundStyle(projectColor(project))
                                    .frame(width: 18, height: 18)
                            }
                        } else {
                            Image(systemName: "app")
                                .frame(width: 18, height: 18)
                        }
                        Text(appState.activeProject?.name ?? "App")
                            .lineLimit(1)
                    }
                    .tag(AppTab.app)
                }

                // Release group
                Section("Release") {
                    ForEach(AppTab.Group.release.tabs) { tab in
                        navigationRow(tab)
                    }
                }

                // Insights group
                Section("Insights") {
                    ForEach(AppTab.Group.insights.tabs) { tab in
                        navigationRow(tab)
                    }
                }

                // TestFlight group
                Section("TestFlight") {
                    ForEach(AppTab.Group.testFlight.tabs) { tab in
                        navigationRow(tab)
                    }
                }

            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 2) {
                // Reuse the native sidebar row rather than drawing a separate
                // button, so icon sizing, tint and selection stay consistent.
                List(selection: $appState.activeTab) {
                    navigationRow(.settings)
                }
                .listStyle(.sidebar)
                .scrollDisabled(true)
                .frame(height: 42)

                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
                    .textSelection(.enabled)
            }
            .padding(.bottom, 12)
        }
    }

    private func navigationRow(_ tab: AppTab) -> some View {
        Label(tab.label, systemImage: tab.icon)
            .tag(tab)
    }

    private func projectIcon(_ project: Project) -> String {
        if project.platform == .macOS { return "desktopcomputer" }
        switch project.type {
        case .reactNative: return "atom"
        case .swift: return "swift"
        case .flutter: return "bird"
        }
    }

    private func projectColor(_ project: Project) -> Color {
        switch project.type {
        case .reactNative: return .cyan
        case .swift: return .orange
        case .flutter: return .blue
        }
    }
}
