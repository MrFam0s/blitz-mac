// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

struct ProjectBundleIDSelectorView: View {
    var appState: AppState
    var asc: ASCManager
    var tab: AppTab
    var platform: ProjectPlatform = .iOS
    var title: String = "App-Store-Zuordnung"
    var subtitle: String? = nil
    var standalone: Bool = false

    @State private var discoveredBundleIds: [String] = []
    @State private var selectedBundleId = ""
    @State private var manualBundleId = ""
    @State private var showManualEntry = false
    @State private var isSaving = false
    @State private var isResolvingCandidates = false
    @State private var candidateResolutionID: UUID?
    @State private var isASCFilteredSelection = false
    @State private var error: String?
    @State private var showRegistrationFlow = false

    private var currentProject: Project? {
        appState.activeProject
    }

    private var currentBundleId: String? {
        normalized(appState.activeProject?.metadata.bundleIdentifier)
    }

    private var usesManualEntry: Bool {
        showManualEntry || !manualBundleId.isEmpty || selectionOptions.isEmpty
    }

    private var effectiveBundleId: String? {
        usesManualEntry ? normalized(manualBundleId) : normalized(selectedBundleId)
    }

    private var isImportedProject: Bool {
        guard let projectPath = currentProject?.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: projectPath),
              let fileType = attrs[.type] as? FileAttributeType else {
            return false
        }
        return fileType == .typeSymbolicLink
    }

    private var selectionOptions: [String] {
        if isASCFilteredSelection {
            return discoveredBundleIds
        }

        var options: [String] = []

        if let currentBundleId {
            options.append(currentBundleId)
        }

        options.append(contentsOf: discoveredBundleIds)

        var seen: Set<String> = []
        return options.filter { seen.insert($0).inserted }
    }

    private var resolvedSubtitle: String {
        if let subtitle {
            return subtitle
        }

        if asc.app == nil {
            return "Für dieses Projekt wurde keine App in App Store Connect gefunden. Prüfe die Zuordnung oder starte die Einrichtung einer neuen App."
        }

        return "Wähle die App-Kennung, mit der dieses Projekt seine Daten aus App Store Connect lädt."
    }

    private var discoveryDescription: String {
        if isASCFilteredSelection {
            return discoveredBundleIds.count == 1
                ? "Passender App-Store-Eintrag gefunden."
                : "\(discoveredBundleIds.count) Kennungen mit App-Store-Eintrag gefunden."
        }
        if selectionOptions.count == 1, let value = selectionOptions.first {
            return discoveredBundleIds.contains(value) ? "Im Projekt erkannt." : "Für dieses Projekt gespeichert."
        }
        return "Wähle die Kennung des gewünschten App-Ziels."
    }

    private var primaryButtonTitle: String {
        asc.app == nil ? "Kennung verwenden" : "Zuordnung übernehmen"
    }

    private var canSubmitSelection: Bool {
        effectiveBundleId != nil && !isSaving
    }

    private var pickerSelection: Binding<String> {
        Binding(
            get: { selectedBundleId },
            set: { newValue in
                selectedBundleId = newValue
                manualBundleId = ""
            }
        )
    }

    private var discoveryTaskKey: String {
        [
            appState.activeProjectId ?? "",
            currentProject?.path ?? "",
            currentBundleId ?? "",
            currentProject?.metadata.selectedReleaseTargetId ?? "",
        ].joined(separator: "::")
    }

    var body: some View {
        Group {
            if currentProject == nil {
                ASCNoProjectSelectedView()
            } else if showRegistrationFlow || asc.activeAppCreationFormRequest != nil {
                BundleIDSetupView(appState: appState, asc: asc, tab: tab, platform: platform)
            } else if isResolvingCandidates {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("App-Store-Zuordnung wird geprüft …")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if standalone {
                ScrollView {
                    content
                        .padding(32)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .onChange(of: asc.activeAppCreationFormRequest?.id) { _, requestID in
            if requestID != nil { showRegistrationFlow = true }
        }
        .onChange(of: discoveryTaskKey) { _, _ in
            showManualEntry = false
            manualBundleId = ""
        }
        .task(id: discoveryTaskKey) {
            await reloadDiscoveredBundleIds()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(standalone ? .title2.weight(.semibold) : .headline)
                Text(resolvedSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Bundle-ID")
                    .font(.callout.weight(.medium))

                if usesManualEntry {
                    TextField("org.beispiel.MeineApp", text: $manualBundleId)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Bundle-ID manuell eingeben")

                    Text(selectionOptions.isEmpty
                        ? "Keine Kennung erkannt. Gib die Bundle-ID des App-Ziels ein."
                        : "Die eingegebene Kennung wird für diese Zuordnung verwendet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if selectionOptions.count == 1, let bundleID = selectionOptions.first {
                    Text(bundleID)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    Text(discoveryDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Bundle-ID", selection: pickerSelection) {
                        if selectedBundleId.isEmpty { Text("App-Kennung auswählen").tag("") }
                        ForEach(selectionOptions, id: \.self) { bundleId in
                            Text(bundleId).tag(bundleId)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Bundle-ID auswählen")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(discoveryDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !selectionOptions.isEmpty {
                    Button(usesManualEntry ? "Zur Projektauswahl zurück" : "Andere Bundle-ID eingeben") {
                        if usesManualEntry {
                            manualBundleId = ""
                            showManualEntry = false
                        } else {
                            showManualEntry = true
                        }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
            .disabled(isSaving)

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BlitzFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                Button(primaryButtonTitle) {
                    Task { await applySelectedBundleId() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmitSelection)

                Button("Neu erkennen") {
                    Task { await reloadDiscoveredBundleIds() }
                }
                .buttonStyle(.bordered)
                .help("Bundle-IDs erneut aus dem Projekt lesen")
                .disabled(isResolvingCandidates || isSaving)
            }

            Button("Neue App einrichten …") {
                showRegistrationFlow = true
            }
            .buttonStyle(.link)
            .font(.callout)
            .help("Öffnet die separate Einrichtung. Die Angaben werden dort bestätigt.")
            .disabled(isSaving)

        }
        .padding(standalone ? 0 : 16)
        .background {
            if !standalone {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.background.secondary)
            }
        }
    }

    private func reloadDiscoveredBundleIds() async {
        guard let project = currentProject else {
            discoveredBundleIds = []
            selectedBundleId = ""
            isASCFilteredSelection = false
            return
        }

        if asc.activeAppCreationFormRequest != nil {
            showRegistrationFlow = true
            return
        }
        let projectURL = URL(fileURLWithPath: project.path)
        let candidates = ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: projectURL)
        error = nil
        isASCFilteredSelection = false

        // Newly created local Blitz projects should go directly to bundle registration
        // when ASC app lookup fails, instead of showing a one-option selector.
        if standalone, asc.app == nil, !isImportedProject {
            discoveredBundleIds = candidates
            applyDefaultSelection(candidates)
            showRegistrationFlow = true
            return
        }

        // Fallback mode only: when app lookup failed and multiple targets were discovered,
        // keep only bundle IDs that already map to ASC apps before deciding the next UI.
        if standalone, asc.app == nil, candidates.count > 1, !showManualEntry, manualBundleId.isEmpty {
            showRegistrationFlow = false
            await resolveFallbackCandidates(candidates)
            return
        }

        showRegistrationFlow = false
        discoveredBundleIds = candidates
        applyDefaultSelection(candidates)
    }

    @MainActor
    private func applySelectedBundleId(ifCurrent: (() -> Bool)? = nil) async {
        guard ifCurrent?() != false else { return }
        guard let projectId = appState.activeProjectId else {
            error = "Kein Projekt ausgewählt."
            return
        }

        guard let bundleId = effectiveBundleId else {
            error = "Wähle eine Bundle-ID aus oder gib sie ein."
            return
        }

        isSaving = true
        defer { isSaving = false }
        error = nil

        do {
            let storage = ProjectStorage()
            guard var metadata = storage.readMetadata(projectId: projectId) else {
                throw ProjectOpenError.notABlitzProject
            }

            if normalized(metadata.bundleIdentifier) != bundleId {
                metadata.bundleIdentifier = bundleId
                try storage.writeMetadata(projectId: projectId, metadata: metadata)
            }

            await appState.projectManager.loadProjects()
            guard ifCurrent?() != false, appState.activeProjectId == projectId else { return }

            asc.prepareForProjectSwitch(to: projectId, bundleId: bundleId)
            await asc.loadCredentials(for: projectId, bundleId: bundleId)

            if asc.app != nil {
                await asc.ensureTabData(tab)
            }
        } catch {
            self.error = error.localizedDescription
        }

    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func applyDefaultSelection(_ candidates: [String], restrictToCandidates: Bool = false) {
        if let currentBundleId,
           (!restrictToCandidates || candidates.contains(currentBundleId)) {
            selectedBundleId = currentBundleId
        } else if candidates.count == 1 {
            selectedBundleId = candidates[0]
        } else if restrictToCandidates {
            if !candidates.contains(selectedBundleId) {
                selectedBundleId = candidates.first ?? ""
            }
        } else if !candidates.contains(selectedBundleId) {
            selectedBundleId = ""
        }
    }

    @MainActor
    private func resolveFallbackCandidates(_ candidates: [String]) async {
        guard let service = asc.service else {
            discoveredBundleIds = candidates
            applyDefaultSelection(candidates)
            return
        }

        let requestID = UUID()
        candidateResolutionID = requestID
        let projectID = appState.activeProjectId
        let revision = asc.projectRevision
        let account = DashboardSummaryStore.accountKey(for: asc.credentials)
        let setupOperationID = asc.pendingBundleIDSetup?.operationId
        let formRequestID = asc.activeAppCreationFormRequest?.id
        func isCurrentDiscovery() -> Bool {
            !Task.isCancelled && candidateResolutionID == requestID
                && appState.activeProjectId == projectID && asc.projectRevision == revision
                && DashboardSummaryStore.accountKey(for: asc.credentials) == account
                && asc.pendingBundleIDSetup?.operationId == setupOperationID
                && asc.activeAppCreationFormRequest?.id == formRequestID
        }
        isResolvingCandidates = true
        defer {
            if candidateResolutionID == requestID { isResolvingCandidates = false }
        }

        do {
            let candidatesWithApps = try await filterCandidatesWithApps(candidates, service: service)
            guard isCurrentDiscovery() else { return }
            switch candidatesWithApps.count {
            case 0:
                discoveredBundleIds = []
                selectedBundleId = ""
                isASCFilteredSelection = true
                showRegistrationFlow = true
            case 1:
                discoveredBundleIds = candidatesWithApps
                isASCFilteredSelection = true
                selectedBundleId = candidatesWithApps[0]
                await applySelectedBundleId(ifCurrent: isCurrentDiscovery)
            default:
                discoveredBundleIds = candidatesWithApps
                isASCFilteredSelection = true
                applyDefaultSelection(candidatesWithApps, restrictToCandidates: true)
            }
        } catch {
            guard isCurrentDiscovery() else { return }
            discoveredBundleIds = candidates
            applyDefaultSelection(candidates)
            isASCFilteredSelection = false
            self.error = "Could not verify discovered bundle IDs in App Store Connect: \(error.localizedDescription)"
        }
    }

    private func filterCandidatesWithApps(
        _ candidates: [String],
        service: AppStoreConnectService
    ) async throws -> [String] {
        var matched: [String] = []
        for candidate in candidates {
            do {
                _ = try await service.fetchApp(bundleId: candidate)
                matched.append(candidate)
            } catch let error as ASCError {
                if case .notFound = error {
                    continue
                }
                throw error
            }
        }
        return matched
    }
}
