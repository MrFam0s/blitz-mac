import SwiftUI

struct ReleaseAutomationSheet: View {
    var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var context: ReleaseAutomationContext?
    @State private var preflight: ReleasePreflight?
    @State private var error: String?

    private var agent: AIAgent { AIAgent(rawValue: appState.settingsStore.defaultAgentCLI) ?? .claudeCode }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update automatisch veröffentlichen").font(.title2.weight(.semibold))
            Text("Prüft Build und Store-Stand, führt Tests aus und reicht das Update bei Apple ein. Nach Apples Freigabe wird es automatisch veröffentlicht.")
                .foregroundStyle(.secondary)

            if let context {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.appName).font(.headline)
                    Text(context.projectPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Store-Version: \(context.displayedLiveVersion ?? "unbekannt") · \(context.platform.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let draft = context.preparedVersion {
                    Label("Vorbereiteter Entwurf: Version \(draft.version)", systemImage: "doc.text")
                        .font(.headline)
                    Text("Gespeicherte Texte, Screenshots und App-Preview-Videos dieses Entwurfs bleiben erhalten. Starte erst, wenn eure Bearbeitung abgeschlossen ist. Fehlende Release Notes werden ergänzt.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Für ein normales App-Update werden eine neue Version und der passende Changelog vorbereitet. Vorhandene Store-Texte und Medien bleiben erhalten.")
                        .font(.callout).foregroundStyle(.secondary)
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
                Label("App- und Store-Änderungen prüfen und Tests ausführen", systemImage: "checkmark.circle")
                Label(context?.preparedVersion == nil ? "Version und Changelog für die Store-Sprachen erstellen" : "Entwurf prüfen und fehlende Release Notes ergänzen", systemImage: "text.badge.plus")
                Label("Build hochladen und bei Apple zur Prüfung einreichen", systemImage: "arrow.up.circle")
                Label("Nach Apples Freigabe automatisch veröffentlichen", systemImage: "app.badge.checkmark")
            }.font(.callout)
            Text("Startet \(agent.displayName) im Blitz-Terminal. Ohne neuen App-Stand oder vorbereitete Store-Änderungen wird nichts eingereicht. Fehlende Angaben oder fehlgeschlagene Tests stoppen den Ablauf.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            Divider()
            HStack {
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Update automatisch veröffentlichen") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(context == nil || preflight == nil)
            }
        }
        .padding(24)
        .frame(width: 620)
        .task {
            guard let project = appState.activeProject, let app = appState.ascManager.app,
                  project.metadata.bundleIdentifier == app.bundleId else {
                error = "Für den automatischen Ablauf muss die App mit ihrem lokalen Projekt verknüpft sein. Ein Entwurf kann über „Versionsentwurf anlegen“ erstellt werden."
                return
            }
            let revision = appState.ascManager.projectRevision
            let versions: [ASCAppStoreVersion]
            let prepared: PreparedReleaseVersion?
            do {
                guard let service = appState.ascManager.service else { throw ASCError.notFound("ASC ist nicht verbunden.") }
                versions = try await service.fetchAppStoreVersions(appId: app.id)
                guard !Task.isCancelled, appState.ascManager.projectRevision == revision,
                      appState.ascManager.app?.id == app.id else { return }
                prepared = try ReleaseAutomationService.preparedVersion(in: versions)
                appState.ascManager.appStoreVersions = versions
            } catch { self.error = error.localizedDescription; return }
            let target = ReleaseAutomationContext(
                projectID: project.id,
                projectPath: URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path,
                appID: app.id, appName: app.name, bundleID: app.bundleId, platform: project.platform,
                displayedLiveVersion: ASCReleaseStatus.currentLiveVersion(for: versions)?.attributes.versionString,
                preparedVersion: prepared
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
        guard context.matches(project: appState.activeProject, app: appState.ascManager.app),
              ReleaseAutomationService.matchesPreparedVersion(context, versions: appState.ascManager.appStoreVersions) else {
            error = "Die ausgewählte App oder ihr Entwurf hat sich geändert. Bitte schließe den Dialog und starte erneut."
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

struct VersionDraftSheet: View {
    var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var asc: ASCManager { appState.ascManager }

    @State private var versionString = ""
    @State private var copyFromVersionId = ""
    @State private var copyMetadata = true
    @State private var copyReviewDetail = true
    @State private var isChecking = true
    @State private var targetRevision: UUID?
    @State private var targetAppID: String?

    private var sourceVersions: [ASCAppStoreVersion] {
        asc.appStoreVersions
    }

    private var blockerMessage: String? {
        asc.newVersionCreationBlockerMessage(desiredVersionString: versionString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Versionsentwurf anlegen")
                .font(.title2.weight(.semibold))

            Text("Legt nur einen Entwurf in App Store Connect an. Danach könnt ihr Texte und Screenshots in Blitz oder per Codex bearbeiten. Videos lassen sich per Codex/ASC oder in App Store Connect pflegen. Es wird kein Build hochgeladen und nichts eingereicht.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Version")
                    .font(.callout.weight(.medium))
                TextField("z. B. 1.4.2", text: $versionString)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Store-Texte der bisherigen Version übernehmen", isOn: $copyMetadata)
                Toggle("Review-Kontaktdaten übernehmen", isOn: $copyReviewDetail)

                Picker("Übernehmen aus", selection: $copyFromVersionId) {
                    Text("Keine").tag("")
                    ForEach(sourceVersions) { version in
                        Text("Version \(version.attributes.versionString)")
                            .tag(version.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!copyMetadata && !copyReviewDetail)
            }

            Label("Build und Einreichung folgen erst, wenn ihr später die Veröffentlichung startet.", systemImage: "pause.circle")
                .font(.callout).foregroundStyle(.secondary)
            if isChecking { ProgressView("Aktuellen Store-Stand prüfen …").controlSize(.small) }

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
                Button("Abbrechen") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Versionsentwurf anlegen") {
                    Task {
                        guard targetRevision == asc.projectRevision, targetAppID == asc.app?.id else { return }
                        let resolvedSourceVersionId = (copyMetadata || copyReviewDetail) && !copyFromVersionId.isEmpty
                            ? copyFromVersionId
                            : nil
                        await asc.createUpdateVersion(
                            versionString: versionString,
                            platform: appState.activeProject?.platform ?? .iOS,
                            copyFromVersionId: resolvedSourceVersionId,
                            copyMetadata: copyMetadata,
                            copyReviewDetail: copyReviewDetail,
                            attachBuildId: nil
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isChecking || targetAppID == nil || asc.isCreatingVersion
                        || blockerMessage != nil
                        || versionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .disabled(asc.isCreatingVersion)
        .interactiveDismissDisabled(asc.isCreatingVersion)
        .task {
            targetRevision = asc.projectRevision
            targetAppID = asc.app?.id
            asc.versionCreationError = nil
            defer { isChecking = false }
            do {
                guard let appID = targetAppID, let service = asc.service else { throw ASCError.notFound("Keine App oder ASC-Verbindung ausgewählt.") }
                let versions = try await service.fetchAppStoreVersions(appId: appID)
                guard !Task.isCancelled, targetRevision == asc.projectRevision, targetAppID == asc.app?.id else { return }
                asc.appStoreVersions = versions
            } catch { asc.versionCreationError = error.localizedDescription; targetAppID = nil; return }
            if versionString.isEmpty {
                versionString = suggestedNextVersion(from: asc.liveVersion?.attributes.versionString)
            }
            if copyFromVersionId.isEmpty {
                copyFromVersionId = asc.liveVersion?.id ?? asc.appStoreVersions.first?.id ?? ""
            }
        }
    }

    private func suggestedNextVersion(from source: String?) -> String {
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else {
            return "1.0"
        }

        var components = source.split(separator: ".").map(String.init)
        guard let last = components.last, let lastValue = Int(last) else {
            return ""
        }
        components[components.count - 1] = String(lastValue + 1)
        return components.joined(separator: ".")
    }
}
