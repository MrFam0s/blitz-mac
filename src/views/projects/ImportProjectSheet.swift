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
    @State private var savedTargets: [ProjectReleaseTarget] = []
    @State private var selectedReleaseTargetId = ""
    @State private var addingReleaseTarget = false
    @State private var discoveredTargets: [ProjectReleaseTargetDiscovery.Candidate] = []
    @State private var selectedDiscoveredTarget = ""
    @State private var scheme = ""
    @State private var configuration = "Release"
    @State private var destination: String?
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

                if !savedTargets.isEmpty {
                    Toggle("Weiteres Veröffentlichungsziel hinzufügen", isOn: $addingReleaseTarget)
                    if !addingReleaseTarget {
                        Picker("Gespeichertes Ziel", selection: $selectedReleaseTargetId) {
                            ForEach(savedTargets) { Text("\($0.displayName) · \($0.bundleIdentifier ?? "ohne Bundle-ID")").tag($0.id) }
                        }
                        .onChange(of: selectedReleaseTargetId) { _, id in applySavedTarget(id) }
                    }
                }
                if !discoveredTargets.isEmpty {
                    Picker("Xcode-App-Ziel", selection: $selectedDiscoveredTarget) {
                        Text("Manuell auswählen").tag("")
                        ForEach(discoveredTargets) { Text($0.label).tag($0.id) }
                    }
                    .onChange(of: selectedDiscoveredTarget) { _, id in applyDiscoveredTarget(id) }
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
                    if let target = selectedXcodeTarget, target.platform != newPlatform {
                        selectedDiscoveredTarget = ""
                        destination = newPlatform == .iOS ? "generic/platform=iOS" : "generic/platform=macOS"
                    }
                }

                if projectType == .swift {
                    TextField("Scheme", text: $scheme)
                    TextField("Konfiguration", text: $configuration)
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
                    resetDetectedProjectState()
                    return
                }

                let url = URL(fileURLWithPath: trimmed)
                refreshDetectedProjectState(for: url)
            }

            if selectedXcodeTarget?.bundleIdentifier == nil && selectedXcodeTarget != nil {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Exakte Release-Bundle-ID", text: $selectedBundleId)
                    Text("Die Bundle-ID dieses Ziels wird von Xcode bedingt oder abgeleitet. Übernimm die genaue Release-Bundle-ID aus den Build-Einstellungen dieses Ziels; die ID einer anderen Plattform wird nicht automatisch verwendet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if discoveredBundleIds.count > 1 {
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
            let platforms = Set(ProjectReleaseTargetDiscovery.discover(in: url).map(\.platform))
            let detectedPlatform = platforms.count == 1 ? platforms.first! : .iOS
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

    private var selectedXcodeTarget: ProjectReleaseTargetDiscovery.Candidate? {
        discoveredTargets.first { $0.id == selectedDiscoveredTarget }
    }

    private var requiresBundleIdSelection: Bool {
        if let target = selectedXcodeTarget, target.bundleIdentifier == nil {
            return !AppCreationIdentity.validBundleID(selectedBundleId)
        }
        return discoveredBundleIds.count > 1 && selectedBundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resetDetectedProjectState() {
        hasSavedMetadata = false
        savedTargets = []
        selectedReleaseTargetId = ""
        addingReleaseTarget = false
        discoveredTargets = []
        selectedDiscoveredTarget = ""
        discoveredBundleIds = []
        selectedBundleId = ""
        scheme = ""
        configuration = "Release"
        destination = nil
        platform = .iOS
        projectType = .reactNative
    }

    private func refreshDetectedProjectState(for url: URL) {
        errorMessage = nil
        resetDetectedProjectState()
        do {
            let saved = try ProjectStorage().readMetadataFromDirectory(url)
            hasSavedMetadata = saved != nil
            savedTargets = saved?.resolvedReleaseTargets ?? []
            selectedReleaseTargetId = saved?.selectedReleaseTarget?.id ?? ""
            addingReleaseTarget = false
            discoveredTargets = ProjectReleaseTargetDiscovery.discover(in: url)
            selectedDiscoveredTarget = ""
            if let saved {
                platform = saved.resolvedPlatform
                projectType = saved.type
                scheme = saved.buildSettings?.scheme ?? ""
                configuration = saved.buildSettings?.configuration ?? "Release"
                destination = saved.buildSettings?.destination
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
            if saved == nil, let candidate = discoveredTargets.first,
               discoveredTargets.filter({ $0.configuration == "Release" }).count == 1 {
                selectedDiscoveredTarget = candidate.id
                applyDiscoveredTarget(candidate.id)
            }
        } catch {
            discoveredBundleIds = []
            selectedBundleId = ""
            hasSavedMetadata = false
            errorMessage = "The existing project metadata could not be read. It will not be overwritten: \(error.localizedDescription)"
        }
    }

    private func applySavedTarget(_ id: String) {
        guard let target = savedTargets.first(where: { $0.id == id }) else { return }
        platform = target.platform
        selectedBundleId = target.bundleIdentifier ?? ""
        scheme = target.buildSettings?.scheme ?? ""
        configuration = target.buildSettings?.configuration ?? "Release"
        destination = target.buildSettings?.destination
    }

    private func applyDiscoveredTarget(_ id: String) {
        guard let target = discoveredTargets.first(where: { $0.id == id }) else { return }
        platform = target.platform
        scheme = target.scheme
        configuration = target.configuration
        destination = target.destination
        selectedBundleId = target.bundleIdentifier ?? ""
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
                selectedBundleID: selectedBundleId,
                releaseTargetId: selectedReleaseTargetId.isEmpty ? nil : selectedReleaseTargetId,
                addingReleaseTarget: addingReleaseTarget,
                selectedBuildSettings: scheme.isEmpty ? nil : BuildSettings(scheme: scheme, configuration: configuration, destination: destination)
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
