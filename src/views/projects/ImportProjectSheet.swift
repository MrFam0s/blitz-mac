// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

struct ImportProjectSheet: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    @State private var projectPath = ""
    @State private var platform: ProjectPlatform = .iOS
    @State private var projectType: ProjectType = .reactNative
    @State private var discoveredBundleIds: [String] = []
    @State private var selectedBundleId = ""
    @State private var hasSavedMetadata = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Import Project")
                .font(.headline)

            Form {
                HStack {
                    TextField("Project Path", text: $projectPath)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            projectPath = url.path
                            refreshDetectedProjectState(for: url)
                        }
                    }
                }

                Picker("Platform", selection: $platform) {
                    Text("iOS").tag(ProjectPlatform.iOS)
                    Text("macOS").tag(ProjectPlatform.macOS)
                }
                .pickerStyle(.segmented)
                .onChange(of: platform) { _, newPlatform in
                    if newPlatform == .macOS {
                        projectType = .swift
                    }
                }

                if platform == .iOS {
                    Picker("Type", selection: $projectType) {
                        Text("React Native").tag(ProjectType.reactNative)
                        Text("Swift").tag(ProjectType.swift)
                        Text("Flutter").tag(ProjectType.flutter)
                    }
                } else {
                    Picker("Type", selection: $projectType) {
                        Text("Swift").tag(ProjectType.swift)
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: projectPath) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    discoveredBundleIds = []
                    selectedBundleId = ""
                    return
                }

                let url = URL(fileURLWithPath: trimmed)
                refreshDetectedProjectState(for: url)
            }

            if discoveredBundleIds.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bundle ID")
                        .font(.callout.weight(.medium))

                    Picker("Bundle ID", selection: $selectedBundleId) {
                        Text("Select a bundle ID").tag("")
                        ForEach(discoveredBundleIds, id: \.self) { bundleId in
                            Text(bundleId).tag(bundleId)
                        }
                    }

                    Text("Multiple bundle IDs were discovered in this project. Choose the one Blitz Neo should use for App Store Connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let bundleId = discoveredBundleIds.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bundle ID")
                        .font(.callout.weight(.medium))
                    Text(bundleId)
                        .font(.system(.callout, design: .monospaced))
                    Text(hasSavedMetadata ? "Blitz Neo keeps the saved bundle ID. You can switch it later from the ASC overview." : "Blitz Neo will use the discovered bundle ID above. You can switch it later from the ASC overview.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bundle ID")
                        .font(.callout.weight(.medium))
                    Text("No bundle IDs were discovered. You can import now and register or select one later from the ASC overview.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Import") {
                    Task { await importProject() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectPath.isEmpty || isImporting || requiresBundleIdSelection)
            }
        }
        .padding()
        .frame(width: 450)
    }

    private struct DetectedProject {
        let type: ProjectType
        let platform: ProjectPlatform
    }

    /// Detect project type and platform from directory contents.
    private func detectProject(at url: URL) -> DetectedProject? {
        let fm = FileManager.default
        // Flutter: pubspec.yaml with "flutter:" dependency
        let pubspec = url.appendingPathComponent("pubspec.yaml")
        if fm.fileExists(atPath: pubspec.path),
           let contents = try? String(contentsOf: pubspec, encoding: .utf8),
           contents.contains("flutter:") {
            return DetectedProject(type: .flutter, platform: .iOS)
        }
        // Swift: .xcodeproj, .xcworkspace, or Package.swift
        let dirContents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let hasXcodeProj = dirContents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") })
        let hasPackageSwift = fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
        if hasXcodeProj || hasPackageSwift {
            // Detect macOS vs iOS by checking pbxproj for SDKROOT or MACOSX_DEPLOYMENT_TARGET
            let detectedPlatform = detectSwiftPlatform(at: url, dirContents: dirContents)
            return DetectedProject(type: .swift, platform: detectedPlatform)
        }
        // React Native: package.json with react-native dependency
        let packageJson = url.appendingPathComponent("package.json")
        if fm.fileExists(atPath: packageJson.path),
           let contents = try? String(contentsOf: packageJson, encoding: .utf8),
           contents.contains("\"react-native\"") {
            return DetectedProject(type: .reactNative, platform: .iOS)
        }
        return nil
    }

    /// Check xcodeproj for macOS vs iOS indicators
    private func detectSwiftPlatform(at url: URL, dirContents: [String]) -> ProjectPlatform {
        guard let xcodeproj = dirContents.first(where: { $0.hasSuffix(".xcodeproj") }) else {
            return .iOS
        }
        let pbxprojPath = url.appendingPathComponent(xcodeproj).appendingPathComponent("project.pbxproj").path
        guard let contents = try? String(contentsOfFile: pbxprojPath, encoding: .utf8) else {
            return .iOS
        }
        if contents.contains("SDKROOT = macosx") || contents.contains("MACOSX_DEPLOYMENT_TARGET") {
            return .macOS
        }
        return .iOS
    }

    private var requiresBundleIdSelection: Bool {
        discoveredBundleIds.count > 1 && selectedBundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshDetectedProjectState(for url: URL) {
        errorMessage = nil
        do {
            let saved = try ProjectStorage().readMetadataFromDirectory(url)
            hasSavedMetadata = saved != nil
            if let saved {
                platform = saved.resolvedPlatform
                projectType = saved.type
            } else if let detected = detectProject(at: url) {
                platform = detected.platform
                projectType = detected.type
            }

            var candidates = ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: url)
            let savedID = saved?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !savedID.isEmpty && !candidates.contains(savedID) {
                candidates.insert(savedID, at: 0)
            }
            discoveredBundleIds = candidates
            selectedBundleId = !savedID.isEmpty ? savedID : (candidates.count == 1 ? candidates[0] : "")
        } catch {
            discoveredBundleIds = []
            selectedBundleId = ""
            hasSavedMetadata = false
            errorMessage = "The existing project metadata could not be read. It will not be overwritten: \(error.localizedDescription)"
        }
    }

    private func importProject() async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        let url = URL(fileURLWithPath: projectPath.trimmingCharacters(in: .whitespacesAndNewlines))

        // Validate selected type matches detected type
        if let detected = detectProject(at: url) {
            if detected.type != projectType {
                let detectedName: String
                switch detected.type {
                case .reactNative: detectedName = "React Native"
                case .swift: detectedName = "Swift"
                case .flutter: detectedName = "Flutter"
                }
                errorMessage = "This looks like a \(detectedName) project. Please select the correct type."
                return
            }
        }

        if requiresBundleIdSelection {
            errorMessage = "Select which bundle ID this project should use before importing."
            return
        }

        let storage = ProjectStorage()
        do {
            let hydratedMetadata = try storage.metadataForImport(
                directory: url,
                type: projectType,
                platform: platform,
                selectedBundleID: selectedBundleId
            )
            // Write metadata into the original project directory first,
            // then register it as a symlink in ~/.blitz/projects/.
            // This ensures all Blitz files land in the actual project, not a detached directory.
            try storage.writeMetadataToDirectory(url, metadata: hydratedMetadata)
            let projectId = try storage.openProject(at: url)
            // An explicit re-import also brings a previously hidden app back.
            try DashboardVisibilityStore.shared.setHidden(false, for: .localOnly(project: Project(
                id: projectId, metadata: hydratedMetadata, path: url.path
            )))
            storage.ensureMCPConfig(
                projectId: projectId,
                whitelistBlitzMCP: appState.settingsStore.whitelistBlitzMCPTools,
                allowASCCLICalls: appState.settingsStore.allowASCCLICalls
            )
            storage.ensureClaudeFiles(
                projectId: projectId,
                projectType: projectType,
                whitelistBlitzMCP: appState.settingsStore.whitelistBlitzMCPTools,
                allowASCCLICalls: appState.settingsStore.allowASCCLICalls
            )
            AnalyticsService.trackProjectImport(projectType: projectType)
            await appState.projectManager.loadProjects()
            appState.activeTab = .app
            appState.activeAppSubTab = .overview
            appState.activeProjectId = projectId
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
