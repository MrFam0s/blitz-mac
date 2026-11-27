// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
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
    @State private var interfaceLanguage = AppLanguage.stored()

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "Allgemein"
        case integrations = "Integrationen"
        case permissions = "Freigaben"
        case maintenance = "Wartung"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: return L10n.tr("Allgemein")
            case .integrations: return L10n.tr("Integrationen")
            case .permissions: return L10n.tr("Freigaben")
            case .maintenance: return L10n.tr("Wartung")
            }
        }
    }

    private let gateableCategories: [(ApprovalRequest.ToolCategory, String)] = [
        (.ascFormMutation, L10n.tr("Store-Texte und Metadaten ändern")),
        (.ascScreenshotMutation, L10n.tr("Screenshots hochladen")),
        (.ascComplianceMutation, L10n.tr("Erklärungen für Festlandchina abgeben")),
        (.ascPreviewMutation, L10n.tr("Vorschauvideos und Poster ändern")),
        (.ascAvailabilityMutation, L10n.tr("Vertriebsländer ändern")),
        (.ascSubmitMutation, L10n.tr("Zur App-Prüfung einreichen")),
        (.buildPipeline, L10n.tr("Builds ausführen")),
        (.projectMutation, L10n.tr("Projekte ändern")),
        (.settingsMutation, L10n.tr("Einstellungen ändern")),
        (.simulatorControl, L10n.tr("Simulator steuern")),
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
        VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
            Text(L10n.tr("Einstellungen"))
                .font(BlitzLayout.pageTitle)
            ViewThatFits(in: .horizontal) {
                sectionPicker
                    .pickerStyle(.segmented)
                    .fixedSize(horizontal: true, vertical: false)
                HStack {
                    Text(L10n.tr("Bereich"))
                    Spacer(minLength: 8)
                    sectionPicker
                        .pickerStyle(.menu)
                }
            }
            .font(BlitzLayout.toolbarFont)
            .controlSize(.small)

            Form {
                switch selectedSection {
                case .general:
                    generalSection
                case .integrations:
                    MCPSetupSection(mcpServer: mcpServer, agent: currentAgent)
                    TerminalToolsSection(settings: settings)
                case .permissions:
                    agentPermissionsSection
                    blitzPermissionsSection
                case .maintenance:
                    maintenanceSection
                }
            }
            .formStyle(.grouped)
            .font(BlitzLayout.bodyFont)
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

    private var sectionPicker: some View {
        Picker(L10n.tr("Bereich"), selection: $selectedSection) {
            ForEach(SettingsSection.allCases) { section in
                Text(section.label).tag(section)
            }
        }
        .labelsHidden()
    }

    private func settingValue(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).fixedSize()
                Spacer(minLength: 8)
                Text(value).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(value)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        Section(L10n.tr("Sprache")) {
            Picker(L10n.tr("Oberflächensprache"), selection: $interfaceLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.label).tag(language)
                }
            }
            .onChange(of: interfaceLanguage) { _, language in language.save() }
            Text(L10n.tr("Automatisch folgt der bevorzugten macOS-Sprache. Änderungen gelten ab dem nächsten Start von Blitz Neo. App-Store-Texte und Terminal-Inhalte bleiben unverändert."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Section(L10n.tr("Terminal & KI-Agent")) {
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

                    Button(L10n.tr("Andere App auswählen …")) {
                        showTerminalPicker = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        terminalAppIcon(currentTerminal, size: 16)
                        Text(currentTerminal.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 140, alignment: .trailing)
                            .help(currentTerminal.displayName)
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
                Text(L10n.tr("KI-Agent"))
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
                settingValue(L10n.tr("Terminalschrift"), value: TerminalFont.resolved.displayName ?? TerminalFont.resolved.fontName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(L10n.tr("Installierte Nerd Fonts werden für Shell-Symbole automatisch bevorzugt."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if currentTerminal.isBuiltIn && currentAgent == .codex {
                settingValue(L10n.tr("Codex-Sitzung"), value: L10n.tr("Letzte Sitzung im Projekt fortsetzen"))
                    .font(.callout)
                Text(L10n.tr("Ohne frühere Sitzung startet eine neue Unterhaltung. Beim Öffnen wird kein Auftrag gesendet; mit /new beginnst du eine neue Unterhaltung."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L10n.tr("Beim Start einen Auftrag zum aktuellen Tab senden"), isOn: Binding(
                        get: { settings.sendDefaultPrompt },
                        set: { newValue in
                            settings.sendDefaultPrompt = newValue
                            settings.save()
                        }
                    ))

                    learnMore(isExpanded: $showAskAIDetail) {
                        Text(L10n.tr("Blitz Neo sendet beim Start einen Auftrag passend zum geöffneten Tab an \(currentAgent.displayName). Deaktiviert öffnet sich eine leere Sitzung."))
                    }
                }
            }

        }
    }

    private var agentPermissionsSection: some View {
        Section(L10n.tr("Agent-Freigaben")) {
            if currentAgent == .codex {
                Text(L10n.tr("MCP-Werkzeugauswahl und MCP-Freigaben werden in Codex verwaltet. Die Einrichtung prüfst du unter Integrationen."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Toggle(L10n.tr("Blitz-Werkzeuge automatisch erlauben"), isOn: Binding(
                    get: { settings.whitelistBlitzMCPTools },
                    set: { newValue in
                        settings.whitelistBlitzMCPTools = newValue
                        settings.save()
                        refreshAgentPermissionFiles()
                    }
                ))

                Text(L10n.tr("Gilt gemeinsam für die von Blitz Neo eingerichteten Claude-Code- und OpenCode-Konfigurationen. Eigene Regeln können zusätzlich gelten."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(L10n.tr("ASC-Befehle automatisch erlauben"), isOn: Binding(
                    get: { settings.allowASCCLICalls },
                    set: { newValue in
                        settings.allowASCCLICalls = newValue
                        settings.save()
                        refreshAgentPermissionFiles()
                    }
                ))
            Text(L10n.tr("Gilt agentenübergreifend für die von Blitz Neo eingerichteten Projekte."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if currentAgent == .codex {
                Text(L10n.tr("Legt ASC-Freigaberegeln für Blitz-Projekte an. Codex lädt sie in vertrauenswürdigen Projekten; weitere Codex-Regeln gelten zusätzlich."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Skip permissions toggle (only for agents that support it)
            if currentAgent.skipPermissionsFlag != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L10n.tr("Neue Agent-Sitzungen ohne Bestätigungen starten"), isOn: Binding(
                        get: { settings.skipAgentPermissions },
                        set: { newValue in
                            settings.skipAgentPermissions = newValue
                            settings.save()
                        }
                    ))

                    learnMore(isExpanded: $showSkipPermsDetail) {
                        Text(L10n.tr("\(currentAgent.displayName) führt Werkzeuge ohne seine üblichen Bestätigungen aus. Die Freigaben für Aktionen in Blitz Neo gelten zusätzlich."))
                    }
                }
            }

        }
    }

    private var blitzPermissionsSection: some View {
        Section {
            Text(L10n.tr("Aktivierte Aktionen benötigen in Blitz Neo keine zusätzliche Rückfrage. Prüfungen für App, Version und Einreichung bleiben bestehen."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(L10n.tr("Alle Blitz-Neo-Aktionen automatisch erlauben"), isOn: Binding(
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
            Text(L10n.tr("Aktionen in Blitz Neo"))
        }
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        Section("Blitz Neo") {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev")
            UpdateSettingsRow(autoUpdate: appState.autoUpdate)
        }
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.tr("API-Schlüssel"))
                    Spacer()
                    if appState.ascManager.credentials != nil {
                        Text(L10n.tr("Eingerichtet"))
                            .font(.callout)
                            .foregroundStyle(.green)
                    } else {
                        Text(L10n.tr("Nicht eingerichtet"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(L10n.tr("API-Schlüssel entfernen"), role: .destructive) {
                    showClearCredentialsConfirm = true
                }
                .disabled(appState.ascManager.credentials == nil)

                Text(L10n.tr("Entfernt den gespeicherten API-Schlüssel samt Kennungen. Die separate Apple-Webanmeldung bleibt erhalten."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("App Store Connect")
        }
        .confirmationDialog(
            L10n.tr("App-Store-Connect-API-Schlüssel entfernen?"),
            isPresented: $showClearCredentialsConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("API-Schlüssel entfernen"), role: .destructive) {
                appState.ascManager.deleteCredentials()
            }
        } message: {
            Text(L10n.tr("Der gespeicherte API-Schlüssel und seine Kennungen werden lokal entfernt. Für App Store Connect musst du sie anschließend erneut hinterlegen."))
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
                    Text(L10n.tr("Details"))
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
            terminalResetWarning = L10n.tr("\(missing.displayName) ist nicht mehr installiert. Terminal wird stattdessen verwendet.")
        }
    }
}
