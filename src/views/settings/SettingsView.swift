import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsService
    @Bindable var appState: AppState
    var mcpServer: MCPServerService?

    @State private var selectedSection: SettingsSection = .general
    @State private var showClearCredentialsConfirm = false
    @State private var showTerminalPicker = false
    @State private var showSkipPermsDetail = false
    @State private var showAskAIDetail = false
    @State private var terminalResetWarning: String?
    @State private var shellIntegrationError: String?

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "Allgemein"
        case integrations = "Integrationen"
        case permissions = "Freigaben"
        case maintenance = "Wartung"

        var id: String { rawValue }
    }

    private let gateableCategories: [(ApprovalRequest.ToolCategory, String)] = [
        (.ascFormMutation, "Store-Texte und Metadaten ändern"),
        (.ascScreenshotMutation, "Screenshots hochladen"),
        (.ascSubmitMutation, "Zur App-Prüfung einreichen"),
        (.buildPipeline, "Builds ausführen"),
        (.projectMutation, "Projekte ändern"),
        (.settingsMutation, "Einstellungen ändern"),
        (.simulatorControl, "Simulator steuern"),
    ]

    private var configuredTerminal: TerminalApp {
        TerminalApp.from(settings.defaultTerminal)
    }

    private var currentTerminal: TerminalApp {
        configuredTerminal.resolvedFallback
    }

    private var currentAgent: AIAgent {
        AIAgent(rawValue: settings.defaultAgentCLI) ?? .claudeCode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Einstellungen")
                .font(BlitzLayout.pageTitle)
            Picker("Bereich", selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                switch selectedSection {
                case .general:
                    generalSection
                    simulatorSection
                case .integrations:
                    MCPSetupSection(mcpServer: mcpServer)
                    shellSection
                case .permissions:
                    agentPermissionsSection
                    blitzPermissionsSection
                case .maintenance:
                    maintenanceSection
                }
            }
            .formStyle(.grouped)
            .id(selectedSection)
        }
        .blitzPagePadding()
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            appState.ascManager.loadStoredCredentialsIfNeeded()
            refreshTerminalResetWarning()
        }
        .fileImporter(
            isPresented: $showTerminalPicker,
            allowedContentTypes: [.application]
        ) { result in
            if case .success(let url) = result {
                terminalResetWarning = nil
                settings.defaultTerminal = TerminalApp.custom(url.path).settingsValue
                settings.save()
            }
        }
    }

    private var generalSection: some View {
        Section("Terminal & KI-Agent") {
            // Terminal picker
            HStack {
                Text("Terminal")
                Spacer()
                Menu {
                    terminalMenuItem(.builtIn)

                    Divider()

                    terminalMenuItem(.terminal)

                    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil {
                        terminalMenuItem(.ghostty)
                    }

                    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil {
                        terminalMenuItem(.iterm)
                    }

                    Divider()

                    Button("Andere App auswählen …") {
                        showTerminalPicker = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        terminalAppIcon(currentTerminal, size: 16)
                        Text(currentTerminal.displayName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let terminalResetWarning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(terminalResetWarning)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            // Agent CLI picker
            HStack {
                Text("KI-Agent")
                Spacer()
                Menu {
                    ForEach(AIAgent.allCases, id: \.rawValue) { agent in
                        Button {
                            settings.defaultAgentCLI = agent.rawValue
                            UserDefaults.standard.set(agent.rawValue, forKey: "selectedAIAgent")
                            settings.save()
                        } label: {
                            HStack {
                                Image(nsImage: agent.icon(size: 16))
                                Text(agent.displayName)
                                if currentAgent == agent { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(nsImage: currentAgent.icon(size: 16))
                        Text(currentAgent.displayName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if currentTerminal.isBuiltIn {
                LabeledContent("Terminalschrift", value: TerminalFont.resolved.displayName ?? TerminalFont.resolved.fontName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Installierte Nerd Fonts werden für Shell-Symbole automatisch bevorzugt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if currentTerminal.isBuiltIn && currentAgent == .codex {
                LabeledContent("Codex-Sitzung", value: "Letzte Sitzung im Projekt fortsetzen")
                    .font(.callout)
                Text("Ohne frühere Sitzung startet eine neue Unterhaltung. Beim Öffnen wird kein Auftrag gesendet; mit /new beginnst du eine neue Unterhaltung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Beim Start einen Auftrag zum aktuellen Tab senden", isOn: Binding(
                        get: { settings.sendDefaultPrompt },
                        set: { newValue in
                            settings.sendDefaultPrompt = newValue
                            settings.save()
                        }
                    ))

                    learnMore(isExpanded: $showAskAIDetail) {
                        Text("Blitz sendet beim Start einen Auftrag passend zum geöffneten Tab an \(currentAgent.displayName). Deaktiviert öffnet sich eine leere Sitzung.")
                    }
                }
            }

            Toggle("Bei Werkzeugaufrufen zum passenden Tab wechseln", isOn: $settings.autoNavEnabled)
                .onChange(of: settings.autoNavEnabled) { _, _ in settings.save() }
        }
    }

    private var simulatorSection: some View {
        Section("Simulator") {
            Toggle("Berührungen im Simulator anzeigen", isOn: $settings.showCursor)
                .onChange(of: settings.showCursor) { _, _ in settings.save() }
            if settings.showCursor {
                HStack {
                    Text("Zeigergröße")
                    Slider(value: $settings.cursorSize, in: 10...40, step: 2)
                        .accessibilityLabel("Zeigergröße")
                    Text("\(Int(settings.cursorSize)) px")
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }
                .onChange(of: settings.cursorSize) { _, _ in settings.save() }
            }
        }
    }

    private var shellSection: some View {
        Section("ASC im externen Terminal") {
            VStack(alignment: .leading, spacing: 4) {
                let shellIntegration = ShellIntegrationService()

                Toggle("ASC für externe Terminals bereitstellen", isOn: Binding(
                    get: { settings.enableASCShellIntegration },
                    set: { newValue in
                        shellIntegrationError = nil
                        do {
                            try settings.setASCShellIntegrationEnabled(newValue)
                        } catch {
                            shellIntegrationError = error.localizedDescription
                        }
                    }
                ))
                .disabled(!shellIntegration.isSupported && !settings.enableASCShellIntegration)

                if shellIntegration.isSupported {
                    Text("Stellt `asc` auch in separat geöffneten Terminals bereit. Dafür verwaltet Blitz einen Eintrag in \(shellIntegration.targetRCFileLabel).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Die automatische Einrichtung unterstützt zsh und bash. Erkannt: \(shellIntegration.shellKind.displayName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let shellIntegrationError {
                    Text(shellIntegrationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var agentPermissionsSection: some View {
        Section("KI-Agent") {
            // Whitelist Blitz MCP tools
            Toggle("Blitz-Werkzeuge im Agenten automatisch erlauben", isOn: Binding(
                get: { settings.whitelistBlitzMCPTools },
                set: { newValue in
                    settings.whitelistBlitzMCPTools = newValue
                    settings.save()
                    refreshAgentPermissionFiles()
                }
            ))

            Toggle("ASC-Befehle im Agenten automatisch erlauben", isOn: Binding(
                get: { settings.allowASCCLICalls },
                set: { newValue in
                    settings.allowASCCLICalls = newValue
                    settings.save()
                    refreshAgentPermissionFiles()
                }
            ))

            // Skip permissions toggle (only for agents that support it)
            if currentAgent.skipPermissionsFlag != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Rückfragen des Agenten überspringen", isOn: Binding(
                        get: { settings.skipAgentPermissions },
                        set: { newValue in
                            settings.skipAgentPermissions = newValue
                            settings.save()
                        }
                    ))

                    learnMore(isExpanded: $showSkipPermsDetail) {
                        Text("\(currentAgent.displayName) führt Werkzeuge ohne seine üblichen Bestätigungen aus. Die Freigaben für Aktionen in Blitz gelten zusätzlich.")
                    }
                }
            }

        }
    }

    private var blitzPermissionsSection: some View {
        Section {
            Text("Aktivierte Aktionen führt Blitz ohne zusätzliche Rückfrage aus.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Alle Blitz-Aktionen automatisch erlauben", isOn: Binding(
                get: {
                    gateableCategories.allSatisfy { settings.permissionToggles[$0.0.rawValue] ?? false }
                },
                set: { newValue in
                    for (category, _) in gateableCategories {
                        settings.permissionToggles[category.rawValue] = newValue
                    }
                    settings.save()
                }
            ))
            .fontWeight(.medium)

            ForEach(gateableCategories, id: \.0.rawValue) { category, label in
                Toggle(label, isOn: Binding(
                    get: { settings.permissionToggles[category.rawValue] ?? false },
                    set: { newValue in
                        settings.permissionToggles[category.rawValue] = newValue
                        settings.save()
                    }
                ))
            }
        } header: {
            Text("Aktionen in Blitz")
        }
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        Section("Blitz") {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev")
            UpdateSettingsRow(autoUpdate: appState.autoUpdate)
        }
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Zugangsdaten")
                    Spacer()
                    if appState.ascManager.credentials != nil {
                        Text("Eingerichtet")
                            .font(.callout)
                            .foregroundStyle(.green)
                    } else {
                        Text("Nicht eingerichtet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Zugangsdaten entfernen", role: .destructive) {
                    showClearCredentialsConfirm = true
                }
                .disabled(appState.ascManager.credentials == nil)

                Text("Entfernt den gespeicherten API-Schlüssel samt Kennungen. Danach ist für App Store Connect eine erneute Einrichtung nötig.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("App Store Connect")
        }
        .confirmationDialog(
            "App-Store-Connect-Zugangsdaten entfernen?",
            isPresented: $showClearCredentialsConfirm,
            titleVisibility: .visible
        ) {
            Button("Zugangsdaten entfernen", role: .destructive) {
                appState.ascManager.deleteCredentials()
            }
        } message: {
            Text("Der gespeicherte API-Schlüssel und seine Kennungen werden lokal entfernt. Für App Store Connect musst du sie anschließend erneut hinterlegen.")
        }

    }

    private func learnMore<Content: View>(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text("Details")
                }
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refreshAgentPermissionFiles() {
        let whitelistBlitzMCP = settings.whitelistBlitzMCPTools
        let allowASCCLICalls = settings.allowASCCLICalls
        let activeProjectId = appState.activeProjectId
        let activeProjectType = appState.activeProject?.type

        Task.detached(priority: .utility) {
            let storage = ProjectStorage()
            storage.ensureGlobalMCPConfigs(
                whitelistBlitzMCP: whitelistBlitzMCP,
                allowASCCLICalls: allowASCCLICalls
            )
            storage.ensureAllProjectMCPConfigs(
                whitelistBlitzMCP: whitelistBlitzMCP,
                allowASCCLICalls: allowASCCLICalls
            )

            if let activeProjectId, let activeProjectType {
                storage.ensureMCPConfig(
                    projectId: activeProjectId,
                    whitelistBlitzMCP: whitelistBlitzMCP,
                    allowASCCLICalls: allowASCCLICalls
                )
                storage.ensureClaudeFiles(
                    projectId: activeProjectId,
                    projectType: activeProjectType,
                    whitelistBlitzMCP: whitelistBlitzMCP,
                    allowASCCLICalls: allowASCCLICalls
                )
            }
        }
    }

    private func terminalMenuItem(_ terminal: TerminalApp) -> some View {
        Button {
            terminalResetWarning = nil
            settings.defaultTerminal = terminal.settingsValue
            settings.save()
        } label: {
            HStack {
                terminalAppIcon(terminal, size: 16)
                Text(terminal.displayName)
                if currentTerminal == terminal { Image(systemName: "checkmark") }
            }
        }
    }

    @ViewBuilder
    private func terminalAppIcon(_ terminal: TerminalApp, size: CGFloat) -> some View {
        if terminal.isBuiltIn {
            Image(systemName: "terminal.fill")
                .frame(width: size, height: size)
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) {
            let icon = Self.resizedIcon(NSWorkspace.shared.icon(forFile: appURL.path), size: size)
            Image(nsImage: icon)
        } else if case .custom(let path) = terminal {
            let icon = Self.resizedIcon(NSWorkspace.shared.icon(forFile: path), size: size)
            Image(nsImage: icon)
        } else {
            Image(systemName: "terminal")
                .frame(width: size, height: size)
        }
    }

    /// Resize an NSImage to an exact pixel size so SwiftUI renders it at a consistent size.
    private static func resizedIcon(_ image: NSImage, size: CGFloat) -> NSImage {
        let s = NSSize(width: size, height: size)
        let resized = NSImage(size: s)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: s),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1)
        resized.unlockFocus()
        resized.isTemplate = false
        return resized
    }

    private func refreshTerminalResetWarning() {
        let resolution = settings.resolveDefaultTerminal()
        if let missing = resolution.replacedMissingTerminal {
            terminalResetWarning = "\(missing.displayName) ist nicht mehr installiert. Terminal wird stattdessen verwendet."
        }
    }
}
