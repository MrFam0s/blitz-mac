// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Terminal app options for onboarding configuration
enum TerminalApp: Hashable {
    case builtIn
    case terminal
    case ghostty
    case iterm
    case custom(String)

    var id: String {
        switch self {
        case .builtIn: return "builtIn"
        case .terminal: return "terminal"
        case .ghostty: return "ghostty"
        case .iterm: return "iterm"
        case .custom(let path): return path
        }
    }

    var displayName: String {
        switch self {
        case .builtIn: return L10n.tr("Terminal (integriert)")
        case .terminal: return L10n.tr("Terminal (extern)")
        case .ghostty: return L10n.tr("Ghostty (extern)")
        case .iterm: return L10n.tr("iTerm (extern)")
        case .custom(let path):
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return L10n.tr("\(name) (extern)")
        }
    }

    /// Name without the "(external)" suffix — used in onboarding disclosure.
    var shortDisplayName: String {
        switch self {
        case .builtIn: return L10n.tr("Integriertes Terminal")
        case .terminal: return L10n.tr("Terminal")
        case .ghostty: return "Ghostty"
        case .iterm: return "iTerm"
        case .custom(let path):
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }

    var iconName: String {
        switch self {
        case .builtIn: return "terminal"
        case .terminal: return "terminal"
        case .ghostty: return "terminal"
        case .iterm: return "terminal"
        case .custom: return "terminal"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .builtIn: return ""
        case .terminal: return "com.apple.Terminal"
        case .ghostty: return "com.mitchellh.ghostty"
        case .iterm: return "com.googlecode.iterm2"
        case .custom(let path): return path
        }
    }

    var isBuiltIn: Bool {
        if case .builtIn = self { return true }
        return false
    }

    var isAvailable: Bool {
        switch self {
        case .builtIn: return true
        case .custom(let path):
            return FileManager.default.fileExists(atPath: path)
        default:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        }
    }

    /// Missing saved terminals fall back to built-in so launches still work.
    var resolvedFallback: TerminalApp {
        isAvailable ? self : .builtIn
    }

    /// Persist to settings as a string
    var settingsValue: String { id }

    /// Restore from settings string
    static func from(_ value: String) -> TerminalApp {
        switch value {
        case "builtIn": return .builtIn
        case "terminal": return .terminal
        case "ghostty": return .ghostty
        case "iterm": return .iterm
        default: return .custom(value)
        }
    }
}

struct OnboardingView: View {
    private enum Step: Equatable {
        case configuration
        case ascSetup
        case askAI
    }

    @Bindable var appState: AppState
    var onComplete: () -> Void
    /// When true, onboarding is shown just to collect/refresh ASC credentials
    /// (the user has already completed the full flow but their credentials are gone).
    /// Starts at the ASC slide and dismisses as soon as credentials are saved.
    var credentialOnlyMode: Bool

    @State private var currentStep = 0
    @State private var selectedTerminal: TerminalApp = .builtIn
    @State private var selectedAgent: AIAgent = .claudeCode
    @State private var detectedTerminals: [TerminalApp] = []
    @State private var showCustomPicker = false
    @State private var showExternalTerminals = false
    // These default to true and are no longer shown in onboarding UI
    @State private var skipAgentPermissions: Bool = true
    @State private var whitelistBlitzMCPTools: Bool = true
    @State private var allowASCCLICalls: Bool = true

    init(appState: AppState, credentialOnlyMode: Bool = false, onComplete: @escaping () -> Void) {
        self.appState = appState
        self.credentialOnlyMode = credentialOnlyMode
        self.onComplete = onComplete
        let hasStoredCredentials = ASCCredentials.load() != nil
        if credentialOnlyMode {
            self.steps = [.ascSetup]
        } else if hasStoredCredentials {
            self.steps = [.configuration, .askAI]
        } else {
            self.steps = [.configuration, .ascSetup, .askAI]
        }
        _currentStep = State(initialValue: 0)
    }

    // ASC setup state
    @State private var ascIssuerId = ""
    @State private var ascKeyId = ""
    @State private var ascPrivateKey = ""
    @State private var ascPrivateKeyFileName: String?
    @State private var ascShowFilePicker = false
    @State private var ascIsSaving = false
    @State private var ascSaveError: String?
    @State private var ascShowInstructions = false
    private let steps: [Step]

    private var resolvedASCKeyID: String? {
        let trimmed = ascKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return ASCCredentials.keyID(fromPrivateKeyFilename: ascPrivateKeyFileName)
    }

    private var ascIsValid: Bool {
        !ascIssuerId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !ascPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        resolvedASCKeyID != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content area
            Group {
                switch currentSlide {
                case .configuration:
                    configurationStep
                case .ascSetup:
                    slideASCSetup
                case .askAI:
                    slideAskAI
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom bar with dots and buttons
            bottomBar
        }
        .frame(width: 700, height: 440)
        .background(.ultraThickMaterial)
        .task {
            detectedTerminals = detectTerminals()
            if let first = detectedTerminals.first {
                selectedTerminal = first
            }
        }
        .onChange(of: appState.ascManager.pendingCredentialValues) { _, pending in
            if let pending {
                ascIssuerId = pending["issuerId"] ?? ""
                ascKeyId = pending["keyId"] ?? ""
                ascPrivateKey = pending["privateKey"] ?? ""
                ascPrivateKeyFileName = pending["privateKeyFileName"]
                appState.ascManager.pendingCredentialValues = nil
                // Jump to ASC slide so user can verify
                if let ascStepIndex = steps.firstIndex(of: .ascSetup),
                   currentStep != ascStepIndex {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentStep = ascStepIndex
                    }
                }
            }
        }
    }

    private var currentSlide: Step {
        steps[currentStep]
    }

    // MARK: - Step 0: Configuration

    private var configurationStep: some View {
        HStack(spacing: 0) {
            // Left: icon + title
            VStack(spacing: 20) {
                Spacer()

                if let icon = Bundle.appResources.image(forResource: "blitz-icon") {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                } else if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                }

                VStack(spacing: 4) {
                    Text(L10n.tr("Willkommen bei Blitz Neo"))
                        .font(.system(size: 24, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.tr("Richte Blitz Neo ein"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

                Spacer()
            }
            .frame(width: 700 * 0.38)
            .background(.regularMaterial)

            // Right: configuration options
            ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                // Agent CLI selection (first — most users care about this)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Standard-KI-Assistent"))
                        .font(.headline)

                    VStack(spacing: 2) {
                        ForEach(AIAgent.allCases, id: \.rawValue) { agent in
                            agentRow(agent)
                        }
                    }
                }

                // Skip permissions toggle (only if agent supports it)
                if selectedAgent.skipPermissionsFlag != nil {
                    Toggle(isOn: $skipAgentPermissions) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.tr("Freigabeabfragen des Assistenten überspringen"))
                                .font(.callout)
                            Text(L10n.tr("Starten mit \(selectedAgent.skipPermissionsFlag ?? "")"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Divider()

                // Terminal selection
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Terminal"))
                        .font(.headline)

                    // Built-in (recommended) — always shown
                    terminalRow(.builtIn, label: L10n.tr("Integriertes Terminal (empfohlen)"))

                    // External terminals — collapsed under clickable header
                    VStack(alignment: .leading, spacing: 2) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showExternalTerminals.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .rotationEffect(.degrees(showExternalTerminals ? 90 : 0))
                                Text(L10n.tr("Externes Terminal verwenden"))
                                    .font(.callout)
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 10)
                        .padding(.vertical, 4)

                        if showExternalTerminals {
                            ForEach(externalTerminals, id: \.self) { terminal in
                                terminalRow(terminal, label: terminal.shortDisplayName)
                            }

                            Button {
                                showCustomPicker = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder")
                                        .frame(width: 20)
                                    Text(L10n.tr("Anderes Terminal auswählen …"))
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity)
        }
        .fileImporter(
            isPresented: $showCustomPicker,
            allowedContentTypes: [.application]
        ) { result in
            if case .success(let url) = result {
                let custom = TerminalApp.custom(url.path)
                if !detectedTerminals.contains(where: { $0.id == custom.id }) {
                    detectedTerminals.append(custom)
                }
                selectedTerminal = custom
            }
        }
    }

    private var externalTerminals: [TerminalApp] {
        detectedTerminals.filter { !$0.isBuiltIn }
    }

    private func terminalRow(_ terminal: TerminalApp, label: String? = nil) -> some View {
        let isSelected = selectedTerminal == terminal
        return Button {
            selectedTerminal = terminal
        } label: {
            HStack(spacing: 10) {
                terminalIcon(for: terminal)
                    .frame(width: 20, height: 20)
                Text(label ?? terminal.displayName)
                    .font(.body)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func terminalIcon(for terminal: TerminalApp) -> some View {
        if terminal.isBuiltIn {
            Image(systemName: "terminal.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if case .custom(let path) = terminal {
            let icon = NSWorkspace.shared.icon(forFile: path)
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "terminal")
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    private func agentRow(_ agent: AIAgent) -> some View {
        let isSelected = selectedAgent == agent
        return Button {
            selectedAgent = agent
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: agent.icon(size: 20))
                    .frame(width: 20, height: 20)
                Text(agent.displayName)
                    .font(.body)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Slide header

    private func slideHeader(title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .bold))

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
        .padding(.top, 2)
    }

    // MARK: - Slide 1: App Store Connect Setup

    @ViewBuilder
    private var slideASCSetup: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                // Header
                VStack(spacing: 4) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.blue)

                    Text("App Store Connect")
                        .font(.system(size: 20, weight: .bold))

                    Text(
                        L10n.tr("Verbinde deinen API-Schlüssel, um Blitz Neo zu nutzen. Der Schlüssel wird lokal gespeichert und bleibt auf deinem Mac.")
                    )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                // Form fields
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("Issuer-ID"))
                            .font(.callout.weight(.medium))
                        TextField("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", text: $ascIssuerId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel(L10n.tr("Issuer-ID"))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("Privater Schlüssel (.p8)"))
                            .font(.callout.weight(.medium))
                        HStack(spacing: 8) {
                            Button {
                                ascShowFilePicker = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.badge.plus")
                                    Text(ascPrivateKeyFileName ?? L10n.tr(".p8-Datei auswählen …"))
                                }
                            }
                            .font(.callout)

                            if ascPrivateKeyFileName != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.body)
                            }
                        }

                        Text(L10n.tr("Mit „Weiter“ prüft und speichert Blitz Neo diesen Schlüssel."))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        if ascPrivateKeyFileName != nil && resolvedASCKeyID == nil {
                            Text(L10n.tr("Behalte den ursprünglichen Namen der heruntergeladenen .p8-Datei bei, damit Blitz Neo die Schlüssel-ID automatisch erkennt."))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let error = ascSaveError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 440)

                // Action links
                VStack(spacing: 4) {
                    Button {
                        launchASCSetupWithAI()
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
                            Text(L10n.tr("Manuell einrichten"))
                            Image(systemName: "arrow.right")
                                .font(.caption)
                        }
                        .font(.callout.weight(.medium))
                    }

                    // Collapsible instructions
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                ascShowInstructions.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .rotationEffect(.degrees(ascShowInstructions ? 90 : 0))
                                Text(L10n.tr("So erstellst du deinen API-Schlüssel"))
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(.blue)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if ascShowInstructions {
                            VStack(alignment: .leading, spacing: 6) {
                                ascInstructionStep(1, L10n.tr("Öffne **App Store Connect > Benutzer und Zugriff > Integrationen > App Store Connect API**."))
                                ascInstructionStep(2, L10n.tr("Wähle den Tab **Teamschlüssel** statt „Individuelle Schlüssel“."))
                                ascInstructionStep(3, L10n.tr("Klicke auf **+**, um einen neuen Schlüssel zu erstellen."))
                                ascInstructionStep(4, L10n.tr("Wähle **Admin** als Zugriffsrecht und gib dem Schlüssel einen Namen."))
                                ascInstructionStep(5, L10n.tr("Klicke auf **Generieren**."))
                                ascInstructionStep(6, L10n.tr("Kopiere die **Issuer-ID** oben auf der Seite."))
                                ascInstructionStep(7, L10n.tr("Klicke auf **Laden**, um die .p8-Datei zu speichern."))
                                Text(L10n.tr("Die .p8-Datei kann nur einmal heruntergeladen werden. Bewahre sie sicher auf."))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .padding(.leading, 20)
                            }
                            .padding(.top, 6)
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $ascShowFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]
        ) { result in
            if case .success(let url) = result {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    ascPrivateKey = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    ascPrivateKeyFileName = url.lastPathComponent
                }
            }
        }
    }

    @ViewBuilder
    private func ascInstructionStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number).")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(LocalizedStringKey(text))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func validateAndSaveASCCredentials() {
        guard let resolvedASCKeyID else {
            ascSaveError = L10n.tr("Behalte den ursprünglichen Namen der heruntergeladenen .p8-Datei bei, damit Blitz Neo die Schlüssel-ID automatisch erkennt.")
            return
        }
        ascIsSaving = true
        ascSaveError = nil
        let creds = ASCCredentials(
            issuerId: ascIssuerId.trimmingCharacters(in: .whitespaces),
            keyId: resolvedASCKeyID,
            privateKey: ascPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        Task {
            do {
                try await AppStoreConnectService(credentials: creds).validateCredentials()
                // Save through ASCManager, then kick off the shared dashboard prewarm
                // in the background so the main window can open immediately while
                // My Apps shows live loading progress.
                try await appState.ascManager.saveCredentials(
                    creds,
                    projectId: appState.activeProjectId ?? "onboarding",
                    bundleId: appState.activeProject?.metadata.bundleIdentifier
                )
                startDashboardPrewarm()
                // In credential-only mode, we don't need to show the rest of the
                // onboarding flow — just make sure the settings flag is set and
                // dismiss onboarding.
                if credentialOnlyMode {
                    let settings = appState.settingsStore
                    if !settings.hasCompletedOnboarding {
                        settings.hasCompletedOnboarding = true
                        settings.save()
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    onComplete()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentStep += 1
                    }
                }
            } catch {
                ascSaveError = error.localizedDescription
            }
            ascIsSaving = false
        }
    }

    /// Resolve the terminal for onboarding context where the built-in split pane
    /// is unavailable due to the small window size.
    private var onboardingTerminal: TerminalApp {
        let resolved = selectedTerminal.resolvedFallback
        guard resolved.isBuiltIn else { return resolved }
        // Built-in can't render in the onboarding window — fall back to Terminal.app
        return .terminal
    }

    private func launchASCSetupWithAI() {
        let agent = selectedAgent
        let terminal = onboardingTerminal
        let prompt = "Erstelle mit dem Skill /asc-team-key-create einen neuen API-Schlüssel für App Store Connect. Fülle anschließend mit dem MCP-Werkzeug asc_set_credentials das Formular aus, damit ich die Angaben prüfen und speichern kann."
        TerminalLauncher.launch(
            projectPath: BlitzPaths.mcps.path,
            agent: agent,
            terminal: terminal,
            prompt: prompt,
            skipPermissions: skipAgentPermissions
        )
    }

    @MainActor
    private func prewarmDashboardCache() async {
        let accountKey = DashboardSummaryStore.accountKey(for: appState.ascManager.credentials)
        guard let service = appState.ascManager.service else { return }

        await DashboardSummaryStore.shared.refresh(
            for: DashboardSummaryStore.cacheKey(
                accountKey: accountKey,
                credentialActivationRevision: appState.ascManager.credentialActivationRevision
            ),
            accountKey: accountKey,
            service: service,
            projects: appState.projectManager.projects,
            force: true
        )
    }

    private func startDashboardPrewarm() {
        Task(priority: .utility) {
            await prewarmDashboardCache()
        }
    }

    // MARK: - Slide 2: Ask AI

    private var slideAskAI: some View {
        VStack(spacing: 6) {
            slideHeader(
                title: L10n.tr("\(selectedAgent.displayName) in Blitz Neo öffnen"),
                subtitle: L10n.tr("Über das Terminal-Symbol öffnest du \(selectedAgent.displayName). Wähle in der Übersicht eine importierte App aus und bitte den Assistenten, sie im App Store einzureichen.")
            )

            // Demo video — transparent background, aspect fit
            OnboardingVideoPlayer(resourceName: "OpenTerminal")
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Shared Components

    private func onboardingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private var bottomBar: some View {
        HStack {
            if currentStep > 0 {
                Button(L10n.tr("Zurück")) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentStep -= 1
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Page dots
            HStack(spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Circle()
                        .fill(i == currentStep ? Color.accentColor : Color.primary.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            if currentSlide == .ascSetup || currentStep < steps.count - 1 {
                Button {
                    if currentSlide == .ascSetup {
                        validateAndSaveASCCredentials()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentStep += 1
                        }
                    }
                } label: {
                    if currentSlide == .ascSetup && ascIsSaving {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 8)
                    } else {
                        Text(L10n.tr("Weiter"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(currentSlide == .ascSetup && (!ascIsValid || ascIsSaving))
            } else {
                Button(L10n.tr("Loslegen")) {
                    finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Logic

    private func detectTerminals() -> [TerminalApp] {
        var found: [TerminalApp] = [.builtIn]
        let ws = NSWorkspace.shared

        // macOS Terminal
        if ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil {
            found.append(.terminal)
        }

        // Check Ghostty
        if ws.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil {
            found.append(.ghostty)
        }

        // Check iTerm
        if ws.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil {
            found.append(.iterm)
        }

        // Also scan ~/Applications for terminal-like apps
        let homeApps = URL(fileURLWithPath: NSHomeDirectory() + "/Applications")
        if let contents = try? FileManager.default.contentsOfDirectory(at: homeApps, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                // Skip already-detected ones
                if name == "terminal" || name == "ghostty" || name == "iterm" || name == "iterm2" { continue }
                // Include apps that look like terminals
                let terminalNames = ["warp", "kitty", "alacritty", "hyper", "wezterm", "rio", "tabby"]
                if terminalNames.contains(name) {
                    found.append(.custom(url.path))
                }
            }
        }

        return found
    }

    private func finishOnboarding() {
        let settings = appState.settingsStore
        settings.defaultTerminal = selectedTerminal.settingsValue
        settings.defaultAgentCLI = selectedAgent.rawValue
        settings.skipAgentPermissions = skipAgentPermissions
        settings.whitelistBlitzMCPTools = whitelistBlitzMCPTools
        settings.allowASCCLICalls = allowASCCLICalls
        settings.hasCompletedOnboarding = true
        settings.save()

        let whitelistBlitzMCP = whitelistBlitzMCPTools
        let allowASCCLI = allowASCCLICalls
        Task.detached(priority: .utility) {
            ProjectStorage().ensureGlobalMCPConfigs(
                whitelistBlitzMCP: whitelistBlitzMCP,
                allowASCCLICalls: allowASCCLI
            )
        }

        // Also persist agent selection to AppStorage for ConnectAIPopover
        UserDefaults.standard.set(selectedAgent.rawValue, forKey: "selectedAIAgent")

        onComplete()
    }
}

/// Looping video player using AVPlayerLayer on a plain NSView — fully transparent background.
private struct OnboardingVideoPlayer: NSViewRepresentable {
    var resourceName: String = "AIUseDemo"

    func makeNSView(context: Context) -> NSView {
        let view = TransparentPlayerView()

        if let url = Bundle.appResources.url(forResource: resourceName, withExtension: "mp4") {
            let player = AVPlayer(url: url)
            player.isMuted = true
            view.playerLayer.player = player
            view.playerLayer.videoGravity = .resizeAspect

            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }

            player.play()
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// NSView backed by an AVPlayerLayer with a transparent background.
private final class TransparentPlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        playerLayer.backgroundColor = .clear
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
