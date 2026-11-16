// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI
import UniformTypeIdentifiers

struct ASCCredentialForm: View {
    var appState: AppState
    var ascManager: ASCManager
    var projectId: String
    var bundleId: String?

    @State private var issuerId = ""
    @State private var keyId = ""
    @State private var privateKey = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showFilePicker = false
    @State private var showInstructions = false
    @State private var privateKeyFileName: String?

    private var resolvedKeyID: String? {
        let trimmed = keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return ASCCredentials.keyID(fromPrivateKeyFilename: privateKeyFileName)
    }

    private var isValid: Bool {
        !issuerId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !privateKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        resolvedKeyID != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                BlitzSetupHeader(L10n.tr("App Store Connect verbinden"),
                    subtitle: L10n.tr("Hinterlege deinen API-Schlüssel, um App-Daten aus App Store Connect zu laden."))

                // Step-by-step instructions for first-time setup
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showInstructions.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .rotationEffect(.degrees(showInstructions ? 90 : 0))
                            Text(L10n.tr("So erhältst du einen API-Schlüssel"))
                                .font(.callout.weight(.medium))
                        }
                        .foregroundStyle(.blue)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showInstructions {
                        VStack(alignment: .leading, spacing: 8) {
                            instructionStep(1, L10n.tr("Öffne **App Store Connect > Benutzer und Zugriff > Integrationen > App Store Connect API**."))
                            instructionStep(2, L10n.tr("Wähle den Bereich **Teamschlüssel**."))
                            instructionStep(3, L10n.tr("Klicke auf **+**, um einen Schlüssel anzulegen."))
                            instructionStep(4, L10n.tr("Vergib einen Namen und wähle den Zugriff **Admin**."))
                            instructionStep(5, L10n.tr("Klicke auf **Generieren**."))
                            instructionStep(6, L10n.tr("Kopiere die **Issuer ID** oben auf der Seite."))
                            instructionStep(7, L10n.tr("Lade die **.p8-Datei** des neuen Schlüssels herunter."))
                            Text(L10n.tr("Die .p8-Datei lässt sich nur einmal herunterladen. Bewahre sie sicher auf."))
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(.leading, 24)
                        }
                        .padding(.top, 8)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                    BlitzSetupField("Issuer ID", hint: L10n.tr("Die Kennung deines Teams aus App Store Connect.")) {
                        TextField("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", text: $issuerId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .accessibilityLabel("Issuer ID")
                    }

                    BlitzSetupField(L10n.tr("Privater Schlüssel (.p8)"),
                        hint: L10n.tr("Wähle die von Apple heruntergeladene Originaldatei. Die Schlüssel-ID wird aus ihrem Dateinamen erkannt.")) {
                        HStack(spacing: 8) {
                            Button {
                                showFilePicker = true
                            } label: {
                                Label(privateKeyFileName ?? L10n.tr("Schlüsseldatei auswählen …"), systemImage: "doc.badge.plus")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel(L10n.tr("Private Schlüsseldatei auswählen"))
                            .accessibilityValue(privateKeyFileName ?? L10n.tr("Keine Datei ausgewählt"))
                            .help(privateKeyFileName ?? L10n.tr("Originaldatei im Format .p8 auswählen"))

                            if privateKeyFileName != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityLabel(L10n.tr("Datei ausgewählt"))
                            }
                        }
                    }

                    if privateKeyFileName != nil && resolvedKeyID == nil {
                        Text(L10n.tr("Verwende den ursprünglichen Dateinamen der .p8-Datei, damit Blitz Neo die Schlüssel-ID erkennen kann."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let error = saveError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let credError = ascManager.credentialsError {
                    Text(credError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer(minLength: 0)
                    if isSaving {
                        ProgressView().controlSize(.small)
                    }
                    Button(isSaving ? L10n.tr("Wird gespeichert …") : L10n.tr("Zugangsdaten speichern")) {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || isSaving)
                }

                Divider()

                // Action links
                BlitzFlowLayout(horizontalSpacing: 16, verticalSpacing: 8) {
                    Button {
                        let settings = SettingsService.shared
                        let agent = AIAgent(rawValue: settings.defaultAgentCLI) ?? .claudeCode
                        let terminal = settings.resolveDefaultTerminal().terminal
                        let prompt = "Use the /asc-team-key-create skill to create a new App Store Connect API key, then call the asc_set_credentials MCP tool to fill the form so I can verify and save."

                        if terminal.isBuiltIn {
                            appState.showTerminal = true
                            appState.terminalManager.createAgentSession(
                                projectPath: BlitzPaths.mcps.path,
                                agent: agent,
                                prompt: prompt,
                                skipPermissions: settings.skipAgentPermissions
                            )
                        } else {
                            TerminalLauncher.launch(
                                projectPath: BlitzPaths.mcps.path,
                                agent: agent,
                                terminal: terminal,
                                prompt: prompt,
                                skipPermissions: settings.skipAgentPermissions
                            )
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text(L10n.tr("Mit KI einrichten"))
                            Image(systemName: "arrow.right")
                                .font(.caption)
                        }
                        .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)

                    Link(destination: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!) {
                        HStack(spacing: 6) {
                            Image(systemName: "key")
                            Text(L10n.tr("Schlüssel bei Apple verwalten"))
                            Image(systemName: "arrow.right")
                                .font(.caption)
                        }
                        .font(.callout.weight(.medium))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: ascManager.pendingCredentialValues) { _, pending in
            if let pending {
                issuerId = pending["issuerId"] ?? ""
                keyId = pending["keyId"] ?? ""
                privateKey = pending["privateKey"] ?? ""
                privateKeyFileName = pending["privateKeyFileName"]
                ascManager.pendingCredentialValues = nil
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]
        ) { result in
            if case .success(let url) = result {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    privateKey = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    privateKeyFileName = url.lastPathComponent
                }
            }
        }
    }

    @ViewBuilder
    private func instructionStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(LocalizedStringKey(text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        guard let resolvedKeyID else {
            saveError = L10n.tr("Verwende den ursprünglichen Dateinamen der .p8-Datei, damit Blitz Neo die Schlüssel-ID erkennen kann.")
            return
        }
        isSaving = true
        saveError = nil
        let creds = ASCCredentials(
            issuerId: issuerId.trimmingCharacters(in: .whitespaces),
            keyId: resolvedKeyID,
            privateKey: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        Task {
            do {
                try await ascManager.saveCredentials(
                    creds,
                    projectId: projectId,
                    bundleId: bundleId
                )
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}
