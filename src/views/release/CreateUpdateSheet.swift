import SwiftUI

struct CreateUpdateSheet: View {
    var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var context: ReleaseAutomationContext?
    @State private var preflight: ReleasePreflight?
    @State private var error: String?
    @State private var showManual = false

    private var agent: AIAgent { AIAgent(rawValue: appState.settingsStore.defaultAgentCLI) ?? .claudeCode }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Neue Version anlegen").font(.title2.weight(.semibold))
            Text("Prüft den lokalen Build und den aktuellen Store-Stand. Bei einem neueren Stand werden Version, Changelog und Einreichung vorbereitet und ausgeführt.")
                .foregroundStyle(.secondary)

            if let context {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.appName).font(.headline)
                    Text(context.projectPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Store-Version: \(context.displayedLiveVersion ?? "unbekannt") · \(context.platform.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let preflight {
                    if preflight.artifacts.isEmpty {
                        Text("Keine passenden lokalen Build-Artefakte gefunden. Der Agent prüft zusätzlich den Quellstand und den Build-Ordner des Projekts.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Lokale Build-Artefakte (\(preflight.artifacts.count))").font(.callout.weight(.medium))
                            ForEach(Array(preflight.artifacts.prefix(3))) { artifact in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: artifact.path).lastPathComponent).lineLimit(1)
                                    Text(artifactDescription(artifact, live: context.displayedLiveVersion))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.help(artifact.path)
                            }
                            if preflight.artifacts.count > 3 { Text("Weitere \(preflight.artifacts.count - 3) im Projektordner").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if preflight.incomplete {
                        Text("Die Vorschau ist unvollständig. Der Ablauf prüft den tatsächlichen Release-Pfad erneut.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Build-Ordner wird geprüft …").font(.callout) }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Label("Neuen Stand nachweisen und nötige Tests ausführen", systemImage: "checkmark.circle")
                Label("Version und Changelog für die vorhandenen Store-Sprachen erstellen", systemImage: "text.badge.plus")
                Label("Build hochladen und bei Apple zur Prüfung einreichen", systemImage: "arrow.up.circle")
                Label("Nach Apples Freigabe automatisch veröffentlichen", systemImage: "app.badge.checkmark")
            }.font(.callout)
            Text("Startet \(agent.displayName) im Blitz-Terminal. Ohne neueren Stand wird nichts eingereicht. Fehlende Angaben oder fehlgeschlagene Tests stoppen die Veröffentlichung; Rückfragen und Fortschritt erscheinen im Terminal.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            Divider()
            HStack {
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Manuell …") { showManual = true }
                Spacer()
                Button("Prüfen und veröffentlichen") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(context == nil || preflight == nil)
            }
        }
        .padding(24)
        .frame(width: 620)
        .sheet(isPresented: $showManual) { ManualCreateUpdateSheet(appState: appState) }
        .task {
            guard let project = appState.activeProject, let app = appState.ascManager.app,
                  project.metadata.bundleIdentifier == app.bundleId else {
                error = "Für den automatischen Ablauf muss die App mit ihrem lokalen Projekt verknüpft sein. Eine Store-Version kannst du auch manuell anlegen."
                return
            }
            let target = ReleaseAutomationContext(
                projectID: project.id,
                projectPath: URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path,
                appID: app.id, appName: app.name, bundleID: app.bundleId, platform: project.platform,
                displayedLiveVersion: appState.ascManager.liveVersion?.attributes.versionString
            )
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.projectPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                error = "Der verknüpfte Projektordner ist nicht erreichbar."
                return
            }
            context = target
            let scan = Task.detached(priority: .utility) { ReleaseAutomationService.scan(target) }
            let result = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
            guard !Task.isCancelled else { return }
            preflight = result
        }
    }

    private func artifactDescription(_ artifact: LocalReleaseArtifact, live: String?) -> String {
        guard let version = artifact.version, let build = artifact.build else { return "App-Zuordnung und Inhalt werden beim Start geprüft" }
        let newer = live.flatMap { ReleaseAutomationService.compareVersions(version, $0) } == .orderedDescending
        return "Version \(version) · Build \(build)" + (newer ? " · neuer als die angezeigte Store-Version" : " · noch kein Nachweis für ein neues Release")
    }

    private func start() {
        guard let context, let preflight else { return }
        guard context.matches(project: appState.activeProject, app: appState.ascManager.app) else {
            error = "Die ausgewählte App hat sich geändert. Bitte schließe den Dialog und starte erneut."
            return
        }
        do {
            let prompt = try ReleaseAutomationService.prompt(context: context, preflight: preflight)
            appState.terminalManager.createAgentSession(
                projectPath: context.projectPath, agent: agent, prompt: prompt,
                skipPermissions: appState.settingsStore.skipAgentPermissions, reuseKey: context.sessionKey
            )
            appState.showTerminal = true
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ManualCreateUpdateSheet: View {
    var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var asc: ASCManager { appState.ascManager }

    @State private var versionString = ""
    @State private var copyFromVersionId = ""
    @State private var copyMetadata = true
    @State private var copyReviewDetail = true
    @State private var attachBuild = true
    @State private var selectedBuildId = ""

    private var validBuilds: [ASCBuild] {
        asc.builds.filter { $0.attributes.processingState == "VALID" && $0.attributes.expired != true }
    }

    private var sourceVersions: [ASCAppStoreVersion] {
        asc.appStoreVersions
    }

    private var blockerMessage: String? {
        asc.newVersionCreationBlockerMessage(desiredVersionString: versionString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Version manuell anlegen")
                .font(.title2.weight(.semibold))

            Text("Create the next App Store version for this live app, optionally copying metadata and review contact details from an existing version.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Version")
                    .font(.callout.weight(.medium))
                TextField("e.g. 1.2.4", text: $versionString)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Copy store listing metadata from an existing version", isOn: $copyMetadata)
                Toggle("Copy review contact details", isOn: $copyReviewDetail)

                Picker("Copy From", selection: $copyFromVersionId) {
                    Text("None").tag("")
                    ForEach(sourceVersions) { version in
                        Text("Version \(version.attributes.versionString)")
                            .tag(version.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!copyMetadata && !copyReviewDetail)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Attach a build now", isOn: $attachBuild)

                Picker("Build", selection: $selectedBuildId) {
                    Text("None").tag("")
                    ForEach(validBuilds) { build in
                        Text("Build \(build.attributes.version)")
                            .tag(build.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!attachBuild)

                if attachBuild && validBuilds.isEmpty {
                    Text("No valid builds are available yet. You can still create the update and attach a build later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let blockerMessage {
                Text(blockerMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let error = asc.versionCreationError, !error.isEmpty {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Update") {
                    Task {
                        let resolvedSourceVersionId = (copyMetadata || copyReviewDetail) && !copyFromVersionId.isEmpty
                            ? copyFromVersionId
                            : nil
                        let resolvedBuildId = attachBuild && !selectedBuildId.isEmpty ? selectedBuildId : nil
                        await asc.createUpdateVersion(
                            versionString: versionString,
                            platform: appState.activeProject?.platform ?? .iOS,
                            copyFromVersionId: resolvedSourceVersionId,
                            copyMetadata: copyMetadata,
                            copyReviewDetail: copyReviewDetail,
                            attachBuildId: resolvedBuildId
                        )
                        if asc.versionCreationError == nil {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    asc.isCreatingVersion
                        || blockerMessage != nil
                        || versionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            if asc.builds.isEmpty {
                await asc.refreshTabData(.builds)
            }
            if versionString.isEmpty {
                versionString = suggestedNextVersion(from: asc.liveVersion?.attributes.versionString)
            }
            if copyFromVersionId.isEmpty {
                copyFromVersionId = asc.liveVersion?.id ?? asc.appStoreVersions.first?.id ?? ""
            }
            if selectedBuildId.isEmpty {
                selectedBuildId = validBuilds.first?.id ?? ""
            }
        }
    }

    private func suggestedNextVersion(from source: String?) -> String {
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else {
            return ""
        }

        var components = source.split(separator: ".").map(String.init)
        guard let last = components.last, let lastValue = Int(last) else {
            return ""
        }
        components[components.count - 1] = String(lastValue + 1)
        return components.joined(separator: ".")
    }
}
