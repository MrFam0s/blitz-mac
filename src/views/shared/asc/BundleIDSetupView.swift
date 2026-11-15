import AppKit
import SwiftUI

/// Multi-phase inline view for registering a bundle ID, enabling capabilities,
/// and guiding the user to create their app in App Store Connect.
struct BundleIDSetupView: View {
    var appState: AppState
    var asc: ASCManager
    var tab: AppTab
    var platform: ProjectPlatform = .iOS

    enum Phase {
        case form       // Step 1: fill out org + app name + capabilities
        case creating   // Registering bundle ID + enabling capabilities
        case manual     // Step 2: manual action — create app in ASC
        case confirming // Checking if app exists in ASC
    }

    @State private var phase: Phase = .form
    @State private var bundleIdentifier = ""
    @State private var publicAppName = ""
    @State private var sku = ""
    @State private var primaryLocale = "en-US"
    @State private var restoredPlatform: ProjectPlatform?
    @State private var appliedFormRequestID: UUID?
    private var effectivePlatform: ProjectPlatform { restoredPlatform ?? platform }
    @State private var creationContext: ASCManager.PendingBundleIDSetupContext?
    @State private var canonicalIdentifierNotice: String?
    @State private var viewOperationId = UUID()
    @State private var hasPrefilled = false
    @State private var selectedCapabilities: Set<String> = []
    @State private var progressMessage = ""
    @State private var error: String?
    @State private var createdBundleId = ""
    @State private var createdAppName = ""
    @State private var capabilitiesEnabled = 0
    @State private var showAdditional = false

    @State private var showCreateInstructions = false
    @State private var copiedCreationHandoff = false
    @State private var showProgramLicenseAlert = false
    @State private var programLicenseAlertMessage = ""

    // Capabilities supported by the ASC API (can be enabled automatically)
    private static let capabilities: [(type: String, name: String)] = [
        ("PUSH_NOTIFICATIONS", "Push-Mitteilungen"),
        ("IN_APP_PURCHASE", "In-App-Käufe"),
        ("APPLE_ID_AUTH", "Mit Apple anmelden"),
        ("ICLOUD", "iCloud"),
        ("GAME_CENTER", "Game Center"),
        ("APPLE_PAY", "Apple Pay"),
        ("APP_GROUPS", "App-Gruppen"),
        ("ASSOCIATED_DOMAINS", "Zugeordnete Domains"),
        ("HEALTHKIT", "HealthKit"),
        ("HOMEKIT", "HomeKit"),
        ("SIRIKIT", "Siri"),
        ("NFC_TAG_READING", "NFC-Tags lesen"),
        ("WALLET", "Wallet"),
        ("MAPS", "Karten"),
        ("DATA_PROTECTION", "Datenschutz"),
        ("AUTOFILL_CREDENTIAL_PROVIDER", "Zugangsdaten automatisch ausfüllen"),
        ("ACCESS_WIFI_INFORMATION", "WLAN-Informationen lesen"),
        ("CLASSKIT", "ClassKit"),
        ("NETWORK_EXTENSIONS", "Netzwerkerweiterungen"),
        ("PERSONAL_VPN", "Persönliches VPN"),
        ("MULTIPATH", "Mehrwegeverbindungen"),
        ("HOT_SPOT", "Hotspot"),
        ("WIRELESS_ACCESSORY_CONFIGURATION", "Drahtloses Zubehör"),
        ("INTER_APP_AUDIO", "Audio zwischen Apps"),
        ("NETWORK_CUSTOM_PROTOCOL", "Eigenes Netzwerkprotokoll"),
        ("COREMEDIA_HLS_LOW_LATENCY", "HLS mit geringer Latenz"),
        ("SYSTEM_EXTENSION_INSTALL", "Systemerweiterungen"),
        ("USER_MANAGEMENT", "Benutzerverwaltung"),
    ]

    // Additional capabilities only configurable through the Apple Developer portal
    private static let portalOnlyCapabilities: [String] = [
        "5G-Netzsegmentierung",
        "App Attest",
        "Hintergrundmodi",
        "Kommunikationsmitteilungen",
        "Erweiterter virtueller Adressraum",
        "Familiensteuerung",
        "Schriften",
        "Gruppenaktivitäten",
        "Kopfposition",
        "HealthKit-Schätzwerte neu kalibrieren",
        "HLS-Zwischenvorschauen",
        "Erhöhtes Speicherlimit beim Debuggen",
        "Tagebuchvorschläge",
        "Schlüsselbundfreigabe",
        "Matter-Einrichtungsdaten zulassen",
        "Per MDM verwaltete zugeordnete Domains",
        "Mediengeräte erkennen",
        "Zusammenarbeit in Nachrichten",
        "Installation bei Bedarf",
        "Sprechfunk",
        "Sensible Inhalte analysieren",
        "Mit dir geteilt",
        "Eingelegte SIM für Mobilfunkanbieter",
        "Profil für räumliches Audio",
        "Dauerhafte Ausführung",
        "Zeitkritische Mitteilungen",
        "WeatherKit",
    ]

    // Preserve every entered character. Validation explains invalid identifiers;
    // it never silently transforms a different identifier into a valid one.
    static func sanitizeComponent(_ input: String) -> String { input }

    static func bundleIdentifier(prefix: String, organization: String, appName: String) -> String {
        "\(prefix).\(organization).\(appName)"
    }

    private var bundleIdPreview: String {
        bundleIdentifier
    }

    private var formIdentity: AppCreationIdentity {
        AppCreationIdentity(appName: publicAppName, bundleId: bundleIdPreview, sku: sku,
            platform: effectivePlatform, primaryLocale: primaryLocale)
    }

    private var validationMessage: String? {
        do { try formIdentity.validate(); return nil }
        catch { return error.localizedDescription }
    }

    private var isFormValid: Bool { validationMessage == nil }

    var body: some View {
        Group {
            if appState.activeProject == nil {
                ASCNoProjectSelectedView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                        switch phase {
                        case .form:
                            formContent
                        case .creating:
                            creatingContent
                        case .manual:
                            manualContent
                        case .confirming:
                            confirmingContent
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 560, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { prefill(); applyFormRequest() }
                .onChange(of: asc.activeAppCreationFormRequest?.id) { _, _ in applyFormRequest() }
                .onChange(of: asc.loadedProjectId) { _, _ in resetForProjectChange() }
                .onChange(of: DashboardSummaryStore.accountKey(for: asc.credentials)) { _, _ in resetForProjectChange() }
            }
        }
        .alert("Aktion im Apple-Developer-Konto erforderlich", isPresented: $showProgramLicenseAlert) {
            Button("Apple-Developer-Konto öffnen") {
                NSWorkspace.shared.open(Self.appleDeveloperAccountURL)
            }
            Button("Schließen", role: .cancel) {}
        } message: {
            Text(programLicenseAlertMessage)
        }
    }

    // MARK: - Phase 1: Form

    @ViewBuilder
    private var formContent: some View {
        BlitzSetupHeader("Neue App einrichten", subtitle: "Bereite einen separaten Store-Eintrag für dieses Veröffentlichungsziel vor. Für eine weitere Plattform derselben App verwende die Veröffentlichungsziele und den bestehenden Store-Eintrag.")

        Divider()

        if let error {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
            BlitzSetupField("Bundle-ID", hint: "Technische Kennung mit unveränderter Groß- und Kleinschreibung. Nach der Registrierung lässt sie sich nicht ändern.") {
                TextField("org.beispiel.MeineApp", text: $bundleIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .accessibilityLabel("Bundle-ID")
            }
            BlitzSetupField("App-Store-Name", hint: "Öffentlicher Name mit 2–30 Zeichen, unabhängig von der technischen Kennung.") {
                TextField("Meine App", text: Binding(
                    get: { publicAppName },
                    set: { newValue in
                        let oldValue = publicAppName
                        publicAppName = newValue
                        if sku.isEmpty || sku == "\(oldValue)-\(effectivePlatform.rawValue)" {
                            sku = "\(newValue)-\(effectivePlatform.rawValue)"
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("App-Store-Name")
            }
            BlitzSetupField("SKU", hint: "Dauerhafte interne Kennung: Buchstaben, Zahlen, Punkte, Bindestriche und Unterstriche; keine Leerzeichen.") {
                TextField("MeineApp-\(effectivePlatform.rawValue)", text: $sku)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("SKU")
            }
            BlitzSetupField("Hauptsprache", hint: "Exakter Sprachcode, zum Beispiel de-DE oder en-US.") {
                TextField("de-DE", text: $primaryLocale)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Hauptsprache")
            }
            BlitzSetupField("Plattform") {
                Text(effectivePlatform.rawValue)
                    .font(.callout)
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Divider()

        // Capabilities
        VStack(alignment: .leading, spacing: 8) {
            Text("App-Funktionen")
                .font(.callout.weight(.medium))
            Text("Wähle die benötigten Funktionen. Weitere lassen sich später im Apple-Developer-Portal aktivieren.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(Self.capabilities, id: \.type) { cap in
                    Toggle(cap.name, isOn: Binding(
                        get: { selectedCapabilities.contains(cap.type) },
                        set: { selected in
                            if selected { selectedCapabilities.insert(cap.type) }
                            else { selectedCapabilities.remove(cap.type) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAdditional.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showAdditional ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Weitere Funktionen (\(Self.portalOnlyCapabilities.count))")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            if showAdditional {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Diese Funktionen aktivierst du manuell im ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        + Text("[Developer-Portal](https://developer.apple.com/account/resources/identifiers/list).")
                            .font(.caption)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(Self.portalOnlyCapabilities, id: \.self) { name in
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.square")
                                    .font(.callout)
                                    .foregroundStyle(.quaternary)
                                Text(name)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(10)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }

        Divider()

        // Submit button
        HStack {
            Spacer()
            Button("Bundle-ID registrieren") {
                registerBundleId()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isFormValid)
        }
    }

    // MARK: - Phase 2: Creating

    @ViewBuilder
    private var creatingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(progressMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Phase 3: Manual

    @ViewBuilder
    private var manualContent: some View {
        BlitzSetupHeader("Store-Eintrag anlegen", subtitle: "Die Bundle-ID ist registriert. Lege jetzt die App mit den bestätigten Angaben in App Store Connect an.")

        VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
            BlitzSetupField("Bundle-ID") {
                Text(createdBundleId)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let identity = creationContext?.identity {
                BlitzSetupField("App-Store-Name") {
                    Text(identity.appName).textSelection(.enabled)
                }
                BlitzSetupField("SKU") {
                    Text(identity.sku).textSelection(.enabled)
                }
                Text("\(identity.platform.rawValue) · \(identity.primaryLocale)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if capabilitiesEnabled > 0 {
                Label("Aktivierte App-Funktionen: \(capabilitiesEnabled)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let canonicalIdentifierNotice {
            Label(canonicalIdentifierNotice, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    launchClaudeCodeForAppCreate(bundleId: createdBundleId, inExistingChat: true)
                } label: {
                    Label("Im bestehenden Chat fortsetzen", systemImage: "doc.on.clipboard")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderedProminent)

                if copiedCreationHandoff {
                    Text("Auftrag kopiert. Im Entwicklungs-Chat einfügen, um genau diese bestätigte App anzulegen.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button {
                    launchClaudeCodeForAppCreate(bundleId: createdBundleId, inExistingChat: false)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Im Blitz-Terminal starten")
                        Image(systemName: "arrow.right")
                            .font(.caption)
                    }
                    .font(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                Link(destination: URL(string: "https://appstoreconnect.apple.com/apps")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "key")
                        Text("App Store Connect öffnen")
                        Image(systemName: "arrow.right")
                            .font(.caption)
                    }
                    .font(.callout.weight(.medium))
                }

                // Collapsible instructions
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showCreateInstructions.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .rotationEffect(.degrees(showCreateInstructions ? 90 : 0))
                            Text("Anleitung zur manuellen Einrichtung")
                                .font(.callout.weight(.medium))
                        }
                        .foregroundStyle(.blue)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showCreateInstructions {
                        VStack(alignment: .leading, spacing: 8) {
                            createInstructionStep(1, "Öffne **[App Store Connect](https://appstoreconnect.apple.com/apps)** und klicke auf **+**.")
                            createInstructionStep(2, "Wähle **Neue App**.")
                            createInstructionStep(3, "Wähle Plattform und Hauptsprache wie oben bestätigt.")
                            createInstructionStep(4, "Übernimm den bestätigten App-Store-Namen und wähle die registrierte Bundle-ID.")
                            createInstructionStep(5, "Übernimm die bestätigte **SKU**.")
                            createInstructionStep(6, "Klicke auf **Erstellen**.")
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 12) {
            Text("Store-Eintrag bereits angelegt?")
                .font(.callout.weight(.medium))

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BlitzFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                Button("Angaben bearbeiten") {
                    goBackToBundleRegistrationForm()
                }
                .buttonStyle(.bordered)

                Button("Store-Eintrag prüfen") {
                    confirmAppCreated()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Phase 4: Confirming

    @ViewBuilder
    private var confirmingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Store-Eintrag wird geprüft …")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Actions

    private func resetForProjectChange() {
        viewOperationId = UUID()
        phase = .form
        error = nil
        creationContext = nil
        copiedCreationHandoff = false
        createdBundleId = ""
        createdAppName = ""
        canonicalIdentifierNotice = nil
        selectedCapabilities = []
        bundleIdentifier = ""
        publicAppName = ""
        sku = ""
        primaryLocale = "en-US"
        restoredPlatform = nil
        appliedFormRequestID = nil
        hasPrefilled = false
        prefill()
        applyFormRequest()
    }

    private func applyFormRequest() {
        guard let request = asc.activeAppCreationFormRequest,
              request.id != appliedFormRequestID else { return }
        appliedFormRequestID = request.id
        let identity = request.context.identity
        viewOperationId = UUID()
        creationContext = nil
        copiedCreationHandoff = false
        bundleIdentifier = identity.bundleId
        publicAppName = identity.appName
        sku = identity.sku
        primaryLocale = identity.primaryLocale
        restoredPlatform = identity.platform
        canonicalIdentifierNotice = nil
        createdBundleId = identity.bundleId
        createdAppName = identity.appName
        hasPrefilled = true
        error = request.message
        phase = .form
    }

    private func prefill() {
        guard !hasPrefilled else { return }
        guard let projectId = asc.loadedProjectId,
              let metadata = ProjectStorage().readMetadata(projectId: projectId) else { return }
        hasPrefilled = true
        publicAppName = metadata.name
        sku = metadata.selectedReleaseTarget?.storeBinding?.sku ?? "\(metadata.name)-\(effectivePlatform.rawValue)"
        if let existingBundleId = metadata.bundleIdentifier, !existingBundleId.isEmpty {
            applyBundleIdToForm(existingBundleId)
        } else {
            bundleIdentifier = "com.example.\(metadata.name)"
        }
    }

    private func registerBundleId() {
        let identity = formIdentity
        let originalProjectId = asc.loadedProjectId
        let originalRevision = asc.projectRevision
        let originalAccount = DashboardSummaryStore.accountKey(for: asc.credentials)
        let operation = UUID()
        viewOperationId = operation
        let caps = Array(selectedCapabilities).sorted()
        error = nil
        phase = .creating
        progressMessage = "Bundle-ID und ausgewählte App-Funktionen werden registriert …"
        Task {
            do {
                guard viewOperationId == operation, asc.loadedProjectId == originalProjectId,
                      asc.projectRevision == originalRevision,
                      DashboardSummaryStore.accountKey(for: asc.credentials) == originalAccount else { return }
                let result = try await asc.registerBundleIDForCreation(identity: identity, tab: tab, capabilities: caps)
                guard viewOperationId == operation else { return }
                try asc.validateBundleIDSetupContext(result.context)
                creationContext = result.context
                createdBundleId = result.context.identity.bundleId
                createdAppName = result.context.identity.appName
                canonicalIdentifierNotice = result.canonicalIdentifierNotice
                capabilitiesEnabled = result.capabilitiesEnabled
                phase = .manual
            } catch {
                guard viewOperationId == operation else { return }
                if let ascError = error as? ASCError, ascError.isProgramLicenseAgreementRequired {
                    presentProgramLicenseAgreementAlert(ascError)
                }
                self.error = error.localizedDescription
                phase = .form
            }
        }
    }

    private func confirmAppCreated() {
        guard let context = creationContext else { return }
        let operation = viewOperationId
        error = nil
        phase = .confirming
        Task {
            do {
                _ = try await asc.confirmBundleIDSetupAppCreated(bundleId: context.identity.bundleId,
                    expectedName: context.identity.appName, expectedSKU: context.identity.sku,
                    expectedPlatform: context.identity.platform.rawValue, expectedLocale: context.identity.primaryLocale,
                    projectId: context.projectId, operationId: context.operationId.uuidString,
                    releaseTargetId: context.releaseTargetId)
            } catch {
                guard viewOperationId == operation else { return }
                if let ascError = error as? ASCError, ascError.isProgramLicenseAgreementRequired {
                    presentProgramLicenseAgreementAlert(ascError)
                }
                self.error = error.localizedDescription
                phase = .manual
            }
        }
    }

    private func goBackToBundleRegistrationForm() {
        guard let context = creationContext else { return }
        do {
            try asc.reopenAppCreationForm(projectId: context.projectId, operationId: context.operationId.uuidString)
            applyFormRequest()
        } catch { self.error = error.localizedDescription }
    }

    private func applyBundleIdToForm(_ bundleId: String) {
        bundleIdentifier = bundleId
    }

    // MARK: - Auto-create via AI agent

    private func launchClaudeCodeForAppCreate(bundleId: String, inExistingChat: Bool) {
        do {
            guard let context = creationContext, context.identity.bundleId == bundleId else {
                throw ASCManager.BundleIDSetupConfirmationError.missingBundleId
            }
            try asc.validateBundleIDSetupContext(context)
            let storage = ProjectStorage()
            let projectDir = storage.baseDirectory.appendingPathComponent(context.projectId)
            try ProjectAgentConfigService(baseDirectory: storage.baseDirectory)
                .prepareBundledCreationSkill(projectDir: projectDir)
            try asc.validateBundleIDSetupContext(context)
            let identity = context.identity
            var values: [String: String] = ["appName": identity.appName, "bundleId": identity.bundleId,
                "sku": identity.sku, "platform": identity.platform.rawValue, "primaryLocale": identity.primaryLocale,
                "projectId": context.projectId, "operationId": context.operationId.uuidString,
                "expectedIssuerId": context.expectedIssuerId, "expectedKeyId": context.expectedKeyId,
                "creationMode": "newStoreApp"]
            if let releaseTargetId = context.releaseTargetId { values["releaseTargetId"] = releaseTargetId }
            let identityFile = try ReleaseHandoffService.writeCreationIdentity(values,
                projectDirectory: projectDir, operationID: context.operationId)
            let prompt = try AppCreationAgentPrompt.make(identityFile: identityFile)
            if inExistingChat {
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(prompt, forType: .string) else {
                    throw NSError(domain: "BlitzReleaseHandoff", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Der Auftrag konnte nicht in die Zwischenablage kopiert werden."])
                }
                copiedCreationHandoff = true
                error = nil
                return
            }
            let settings = SettingsService.shared
            let agent = AIAgent(rawValue: settings.defaultAgentCLI) ?? .claudeCode
            let terminal = settings.resolveDefaultTerminal().terminal
            if terminal.isBuiltIn {
                appState.showTerminal = true
                appState.terminalManager.createAgentSession(projectPath: projectDir.path, agent: agent,
                    prompt: prompt, skipPermissions: settings.skipAgentPermissions)
            } else {
                TerminalLauncher.launch(projectPath: projectDir.path, agent: agent, terminal: terminal,
                    prompt: prompt, skipPermissions: settings.skipAgentPermissions)
            }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func createInstructionStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func presentProgramLicenseAgreementAlert(_ error: ASCError) {
        programLicenseAlertMessage = error.programLicenseAgreementMessage + "\n\nÖffne https://developer.apple.com/account und bestätige dort die aktuelle Vereinbarung. Versuche es anschließend erneut."
        showProgramLicenseAlert = true
    }

    private static let appleDeveloperAccountURL = URL(string: "https://developer.apple.com/account")!
}
