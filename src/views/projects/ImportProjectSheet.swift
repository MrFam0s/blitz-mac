// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

struct ImportProjectSheet: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    @State private var projectPath = ""
    @State private var inspectedProjectPath: String?
    @State private var platform: ProjectPlatform = .iOS
    @State private var projectType: ProjectType = .reactNative
    @State private var discoveredBundleIds: [String] = []
    @State private var selectedBundleId = ""
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
        VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
            BlitzSetupHeader("Projekt importieren", subtitle: "Verknüpfe einen vorhandenen Projektordner mit Blitz Neo und prüfe das gewünschte App-Ziel.")

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                    BlitzSetupField("Projektordner") {
                        HStack(spacing: BlitzLayout.fieldSpacing) {
                            TextField("/Pfad/zum/Projekt", text: $projectPath)
                                .accessibilityLabel("Projektordner")
                                .onSubmit { inspectProjectPath() }
                            Button("Auswählen …") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    projectPath = url.path
                                    inspectProjectPath()
                                }
                            }
                            .accessibilityLabel("Projektordner auswählen")
                        }
                        HStack(spacing: BlitzLayout.fieldSpacing) {
                            Button("Ordner prüfen") { inspectProjectPath() }
                                .disabled(normalizedProjectPath.isEmpty || isImporting)
                            Text(hasInspectedProject ? "Ordner geprüft." : "Die Erkennung startet erst beim Prüfen oder Auswählen des Ordners.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !savedTargets.isEmpty {
                        Toggle("Weiteres Veröffentlichungsziel hinzufügen", isOn: $addingReleaseTarget)
                        if !addingReleaseTarget {
                            BlitzSetupField("Gespeichertes Ziel") {
                                Picker("Gespeichertes Ziel", selection: $selectedReleaseTargetId) {
                                    ForEach(savedTargets) { Text("\($0.displayName) · \($0.bundleIdentifier ?? "ohne Bundle-ID")").tag($0.id) }
                                }
                                .accessibilityLabel("Gespeichertes Ziel")
                                .onChange(of: selectedReleaseTargetId) { _, id in applySavedTarget(id) }
                            }
                        }
                    }
                    if !discoveredTargets.isEmpty {
                        BlitzSetupField("Xcode-App-Ziel") {
                            Picker("Xcode-App-Ziel", selection: $selectedDiscoveredTarget) {
                                Text("Manuell auswählen").tag("")
                                ForEach(discoveredTargets) { Text($0.label).tag($0.id) }
                            }
                            .accessibilityLabel("Xcode-App-Ziel")
                            .onChange(of: selectedDiscoveredTarget) { _, id in applyDiscoveredTarget(id) }
                        }
                    }

                    Divider()

                    BlitzSetupField("Plattform") {
                        Picker("Plattform", selection: $platform) {
                            Text("iOS").tag(ProjectPlatform.iOS)
                            Text("macOS").tag(ProjectPlatform.macOS)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Plattform")
                        .onChange(of: platform) { _, newPlatform in
                            if newPlatform == .macOS {
                                projectType = .swift
                            }
                            if let target = selectedXcodeTarget, target.platform != newPlatform {
                                selectedDiscoveredTarget = ""
                                destination = newPlatform == .iOS ? "generic/platform=iOS" : "generic/platform=macOS"
                            }
                        }
                    }
                    BlitzSetupField("Projekttyp") {
                        Picker("Projekttyp", selection: $projectType) {
                            if platform == .iOS {
                                Text("React Native").tag(ProjectType.reactNative)
                                Text("Swift").tag(ProjectType.swift)
                                Text("Flutter").tag(ProjectType.flutter)
                            } else {
                                Text("Swift").tag(ProjectType.swift)
                            }
                        }
                        .accessibilityLabel("Projekttyp")
                    }
                    if projectType == .swift {
                        BlitzSetupField("Xcode-Scheme") {
                            TextField("z. B. MeineApp", text: $scheme)
                                .accessibilityLabel("Xcode-Scheme")
                        }
                        BlitzSetupField("Konfiguration") {
                            TextField("Release", text: $configuration)
                                .accessibilityLabel("Konfiguration")
                        }
                    }

                    if hasInspectedProject { bundleIDField }
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: hasInspectedProject ? 420 : 250)
            .onChange(of: projectPath) { _, _ in
                // Typing can temporarily produce "/" or a broad parent folder.
                // Never traverse it until the user explicitly checks the path.
                // The panel may finish inspection before this onChange runs.
                guard normalizedProjectPath != inspectedProjectPath else { return }
                // Preserve a failed panel inspection's error until the next
                // explicit attempt; onChange may run after that failure too.
                resetDetectedProjectState()
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: BlitzLayout.fieldSpacing) {
                Button("Abbrechen") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isImporting { ProgressView().controlSize(.small) }
                Button("Projekt importieren") {
                    Task { await importProject() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!hasInspectedProject || isImporting || requiresBundleIdSelection)
            }
        }
        .font(.callout)
        .padding(24)
        .frame(width: 560)
    }

    private var normalizedProjectPath: String {
        let trimmed = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return expanded }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    private var hasInspectedProject: Bool {
        !normalizedProjectPath.isEmpty && inspectedProjectPath == normalizedProjectPath
    }

    private func inspectProjectPath() {
        guard !isImporting else { return }
        let path = normalizedProjectPath
        errorMessage = nil
        resetDetectedProjectState()
        guard !path.isEmpty else { return }
        guard path.hasPrefix("/"), path != "/" else {
            errorMessage = "Wähle den konkreten Projektordner oder gib seinen vollständigen Pfad ein."
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "Der Projektordner wurde nicht gefunden. Prüfe den Pfad."
            return
        }
        refreshDetectedProjectState(for: URL(fileURLWithPath: path, isDirectory: true))
    }

    // A saved target may have an identity that is no longer present in the
    // current source tree. Keep its selected value visible without replacing it.
    private var bundleIDOptions: [String] {
        var options = discoveredBundleIds
        if !selectedBundleId.isEmpty, !options.contains(selectedBundleId) {
            options.append(selectedBundleId)
        }
        return options
    }

    @ViewBuilder
    private var bundleIDField: some View {
        if selectedXcodeTarget?.bundleIdentifier == nil && selectedXcodeTarget != nil {
            BlitzSetupField("Bundle-ID", hint: "Dieses Ziel verwendet eine bedingte oder abgeleitete Kennung. Übernimm die genaue Release-Bundle-ID aus seinen Xcode-Build-Einstellungen.") {
                TextField("org.beispiel.MeineApp", text: $selectedBundleId)
                    .font(.system(.callout, design: .monospaced))
                    .accessibilityLabel("Release-Bundle-ID")
            }
        } else if bundleIDOptions.count > 1 {
            BlitzSetupField("Bundle-ID", hint: "Mehrere Kennungen gefunden. Wähle die Kennung des gewünschten App-Ziels für App Store Connect.") {
                Picker("Bundle-ID", selection: $selectedBundleId) {
                    if selectedBundleId.isEmpty { Text("App-Kennung auswählen").tag("") }
                    ForEach(bundleIDOptions, id: \.self) { bundleId in
                        Text(bundleId).tag(bundleId)
                    }
                }
                .accessibilityLabel("Bundle-ID")
            }
        } else if let bundleId = bundleIDOptions.first {
            BlitzSetupField("Bundle-ID", hint: savedTargets.contains(where: { $0.bundleIdentifier == bundleId })
                ? "Für dieses Projekt gespeichert. Die Zuordnung lässt sich später ändern."
                : "Im Projekt erkannt. Die Zuordnung lässt sich später ändern.") {
                Text(bundleId)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        } else if !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            BlitzSetupField("Bundle-ID") {
                Text("Keine Kennung erkannt. Du kannst das Projekt importieren und die Zuordnung anschließend einrichten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
        inspectedProjectPath = nil
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
            inspectedProjectPath = url.standardizedFileURL.path
        } catch {
            resetDetectedProjectState()
            errorMessage = "Die vorhandenen Projektdaten konnten nicht gelesen werden und werden nicht überschrieben: \(error.localizedDescription)"
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
        guard hasInspectedProject else {
            errorMessage = "Prüfe den aktuellen Projektordner vor dem Import."
            return
        }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        let url = URL(fileURLWithPath: normalizedProjectPath, isDirectory: true)

        // Validate selected type matches detected type
        if let detected = detectProject(at: url) {
            if detected.type != projectType {
                let detectedName: String
                switch detected.type {
                case .reactNative: detectedName = "React Native"
                case .swift: detectedName = "Swift"
                case .flutter: detectedName = "Flutter"
                }
                errorMessage = "Dieses Projekt verwendet offenbar \(detectedName). Wähle den passenden Projekttyp."
                return
            }
        }

        if requiresBundleIdSelection {
            errorMessage = "Wähle vor dem Import die Bundle-ID des gewünschten App-Ziels."
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
