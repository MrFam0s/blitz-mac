// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

/// Registers a local release target. Apple mutations remain in the explicitly
/// confirmed new-record and version-draft workflows, never in this dialog.
struct ProjectReleaseTargetSetupView: View {
    var appState: AppState
    var releaseTargetId: String? = nil
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .existingStore
    @State private var platform: ProjectPlatform = .macOS
    @State private var targetName = ""
    @State private var bundleID = ""
    @State private var scheme = ""
    @State private var configuration = "Release"
    @State private var isMacCatalyst = false
    @State private var selectedAppID = ""
    @State private var apps: [ASCApp] = []
    @State private var error: String?
    @State private var busy = false
    @State private var capturedProjectID: String?
    @State private var capturedAccount: String?
    @State private var capturedCredentialRevision = 0

    private enum Mode: String, CaseIterable { case existingStore, separateStore }
    private var selectedApp: ASCApp? { apps.first { $0.id == selectedAppID } }
    private var canSave: Bool {
        !busy && (releaseTargetId != nil || (!scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !configuration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            && (mode == .existingStore ? selectedApp != nil : AppCreationIdentity.validBundleID(bundleID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(releaseTargetId == nil ? "Veröffentlichungsziel hinzufügen" : "Store-Zuordnung prüfen").font(.title2.weight(.semibold))
            Text("Ein Projekt kann mehrere native App-Ziele haben. Wähle bewusst, ob sie denselben Store-Eintrag oder getrennte Einträge verwenden.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("Store-Zuordnung", selection: $mode) {
                    Text("Bestehenden Store-Eintrag verwenden").tag(Mode.existingStore)
                    Text("Separaten Store-Eintrag vorbereiten").tag(Mode.separateStore)
                }
                .disabled(releaseTargetId != nil)
                Picker("Native Plattform", selection: $platform) {
                    ForEach(ProjectPlatform.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.disabled(releaseTargetId != nil)
                if platform == .macOS {
                    Toggle("Mac-Catalyst-Build", isOn: $isMacCatalyst).disabled(releaseTargetId != nil)
                }
                TextField("Zielname (optional)", text: $targetName).disabled(releaseTargetId != nil)
                TextField("Xcode-Scheme", text: $scheme).disabled(releaseTargetId != nil)
                TextField("Konfiguration", text: $configuration).disabled(releaseTargetId != nil)
                if mode == .existingStore {
                    Picker("Store-App", selection: $selectedAppID) {
                        Text("App auswählen").tag("")
                        ForEach(apps) { Text("\($0.name) · \($0.bundleId)").tag($0.id) }
                    }
                    if let app = selectedApp {
                        Text("App-ID \(app.id) · SKU \(app.attributes.sku ?? "unbekannt")\nBundle-ID \(app.bundleId)")
                            .font(.caption).textSelection(.enabled)
                    }
                } else {
                    TextField("Exakte Release-Bundle-ID", text: $bundleID)
                    Text("Eine separate Store-App benötigt eine eigene Bundle-ID und SKU. Nach dem Speichern bestätigst du Name, Bundle-ID und SKU im normalen Anlegeformular.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if mode == .existingStore {
                Text("Die bestehende App-ID, Bundle-ID und SKU bleiben erhalten. Falls die Plattform bei Apple noch fehlt, lege anschließend ausdrücklich einen „Versionsentwurf“ für dieses Ziel an. Hier wird noch nichts bei Apple erstellt oder eingereicht.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Eine iPhone-/iPad-App auf einem Mac mit Apple-Chip bleibt ein iOS-Ziel. Wähle macOS nur für einen eigenen nativen Mac-/Mac-Catalyst-Build.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Ziel speichern") { Task { await save() } }
                    .buttonStyle(.borderedProminent).disabled(!canSave)
            }
        }
        .padding(24).frame(width: 600)
        .task { await load() }
    }

    private func load() async {
        guard let project = appState.activeProject else { error = "Kein lokales Projekt ausgewählt."; return }
        capturedProjectID = project.id
        platform = project.platform == .iOS ? .macOS : .iOS
        if let releaseTargetId {
            guard let target = project.metadata.releaseTarget(id: releaseTargetId) else {
                error = "Das gewählte Veröffentlichungsziel ist nicht mehr vorhanden. Bitte die Zielauswahl erneut öffnen."
                return
            }
            platform = target.platform; targetName = target.name ?? ""
            bundleID = target.bundleIdentifier ?? ""
            scheme = target.buildSettings?.scheme ?? ""
            configuration = target.buildSettings?.configuration ?? "Release"
            isMacCatalyst = target.buildSettings?.destination?.contains("variant=Mac Catalyst") == true
        }
        capturedAccount = DashboardSummaryStore.accountKey(for: appState.ascManager.credentials)
        capturedCredentialRevision = appState.ascManager.credentialActivationRevision
        guard let service = appState.ascManager.service else {
            if releaseTargetId != nil {
                error = "Bitte zuerst bei App Store Connect anmelden, damit die Store-Zuordnung geprüft werden kann."
            } else {
                mode = .separateStore
            }
            return
        }
        busy = true
        defer { busy = false }
        do {
            let fetched = try await service.fetchAllApps()
            try checkContext()
            apps = fetched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            selectedAppID = releaseTargetId.flatMap { project.metadata.releaseTarget(id: $0)?.storeBinding?.appId }
                ?? apps.first(where: { $0.bundleId == bundleID })?.id ?? appState.ascManager.app?.id ?? ""
        } catch { self.error = error.localizedDescription }
    }

    private func checkContext() throws {
        guard appState.activeProjectId == capturedProjectID,
              DashboardSummaryStore.accountKey(for: appState.ascManager.credentials) == capturedAccount,
              appState.ascManager.credentialActivationRevision == capturedCredentialRevision else {
            throw ProjectReleaseTargetError.invalid
        }
    }

    private func save() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try checkContext()
            guard let projectID = capturedProjectID else { throw ProjectReleaseTargetError.missing }
            var target = ProjectReleaseTarget(name: targetName, platform: platform,
                bundleIdentifier: bundleID,
                buildSettings: BuildSettings(scheme: scheme.trimmingCharacters(in: .whitespacesAndNewlines),
                    configuration: configuration.trimmingCharacters(in: .whitespacesAndNewlines),
                    destination: platform == .iOS ? "generic/platform=iOS" : (isMacCatalyst ? "generic/platform=macOS,variant=Mac Catalyst" : "generic/platform=macOS")))
            if let releaseTargetId {
                guard let existing = appState.activeProject?.metadata.releaseTarget(id: releaseTargetId) else { throw ProjectReleaseTargetError.missing }
                target = existing
            }
            if mode == .existingStore {
                guard let selectedApp, let service = appState.ascManager.service,
                      let account = capturedAccount else { throw ProjectReleaseTargetError.invalid }
                let fresh = try await service.fetchApp(id: selectedApp.id)
                try checkContext()
                guard fresh.id == selectedApp.id, fresh.bundleId == selectedApp.bundleId,
                      fresh.attributes.sku == selectedApp.attributes.sku else { throw ProjectReleaseTargetError.invalid }
                if releaseTargetId != nil, let existingBundle = target.bundleIdentifier, existingBundle != fresh.bundleId {
                    throw ProjectReleaseTargetError.boundIdentity
                }
                target.bundleIdentifier = fresh.bundleId
                target.storeBinding = ProjectStoreBinding(appId: fresh.id, accountKey: account,
                    sku: fresh.attributes.sku, bundleIdentifier: fresh.bundleId)
            } else {
                // Do not silently prepare a second record for a known existing ID.
                guard !apps.contains(where: { $0.bundleId.caseInsensitiveCompare(bundleID) == .orderedSame }),
                      !(appState.activeProject?.releaseTargets ?? []).contains(where: {
                          $0.storeBinding != nil && $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
                      }) else {
                    throw NSError(domain: "BlitzReleaseTarget", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "Diese Bundle-ID gehört bereits zu einem Store-Eintrag. Verwende den bestehenden Eintrag oder eine andere, ausdrücklich bestätigte Bundle-ID."])
                }
            }
            var verifiedBindings: [String: ProjectStoreBinding] = [:]
            if let oldTarget = appState.activeProject?.selectedReleaseTarget, oldTarget.storeBinding == nil,
               let oldApp = appState.ascManager.app, oldTarget.bundleIdentifier == oldApp.bundleId,
               let service = appState.ascManager.service, let account = capturedAccount {
                let verified = try await service.fetchApp(id: oldApp.id)
                try checkContext()
                guard verified.id == oldApp.id, verified.bundleId == oldTarget.bundleIdentifier else {
                    throw ProjectReleaseTargetError.invalid
                }
                verifiedBindings[oldTarget.id] = ProjectStoreBinding(appId: verified.id, accountKey: account,
                    sku: verified.attributes.sku, bundleIdentifier: verified.bundleId)
            }
            try checkContext()
            try await appState.projectManager.saveReleaseTarget(projectId: projectID, target: target,
                verifiedBindings: verifiedBindings)
            onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
