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
        ("PUSH_NOTIFICATIONS", L10n.tr("Push-Mitteilungen")),
        ("IN_APP_PURCHASE", L10n.tr("In-App-Käufe")),
        ("APPLE_ID_AUTH", L10n.tr("Mit Apple anmelden")),
        ("ICLOUD", "iCloud"),
        ("GAME_CENTER", "Game Center"),
        ("APPLE_PAY", "Apple Pay"),
        ("APP_GROUPS", L10n.tr("App-Gruppen")),
        ("ASSOCIATED_DOMAINS", L10n.tr("Zugeordnete Domains")),
        ("HEALTHKIT", "HealthKit"),
        ("HOMEKIT", "HomeKit"),
        ("SIRIKIT", "Siri"),
        ("NFC_TAG_READING", L10n.tr("NFC-Tags lesen")),
        ("WALLET", "Wallet"),
        ("MAPS", L10n.tr("Karten")),
        ("DATA_PROTECTION", L10n.tr("Datenschutz")),
        ("AUTOFILL_CREDENTIAL_PROVIDER", L10n.tr("Zugangsdaten automatisch ausfüllen")),
        ("ACCESS_WIFI_INFORMATION", L10n.tr("WLAN-Informationen lesen")),
        ("CLASSKIT", "ClassKit"),
        ("NETWORK_EXTENSIONS", L10n.tr("Netzwerkerweiterungen")),
        ("PERSONAL_VPN", L10n.tr("Persönliches VPN")),
        ("MULTIPATH", L10n.tr("Mehrwegeverbindungen")),
        ("HOT_SPOT", "Hotspot"),
        ("WIRELESS_ACCESSORY_CONFIGURATION", L10n.tr("Drahtloses Zubehör")),
        ("INTER_APP_AUDIO", L10n.tr("Audio zwischen Apps")),
        ("NETWORK_CUSTOM_PROTOCOL", L10n.tr("Eigenes Netzwerkprotokoll")),
        ("COREMEDIA_HLS_LOW_LATENCY", L10n.tr("HLS mit geringer Latenz")),
        ("SYSTEM_EXTENSION_INSTALL", L10n.tr("Systemerweiterungen")),
        ("USER_MANAGEMENT", L10n.tr("Benutzerverwaltung")),
    ]

    // Additional capabilities only configurable through the Apple Developer portal
    private static let portalOnlyCapabilities: [String] = [
        L10n.tr("5G-Netzsegmentierung"),
        "App Attest",
        L10n.tr("Hintergrundmodi"),
        L10n.tr("Kommunikationsmitteilungen"),
        L10n.tr("Erweiterter virtueller Adressraum"),
        L10n.tr("Familiensteuerung"),
        L10n.tr("Schriften"),
        L10n.tr("Gruppenaktivitäten"),
        L10n.tr("Kopfposition"),
        L10n.tr("HealthKit-Schätzwerte neu kalibrieren"),
        L10n.tr("HLS-Zwischenvorschauen"),
        L10n.tr("Erhöhtes Speicherlimit beim Debuggen"),
        L10n.tr("Tagebuchvorschläge"),
        L10n.tr("Schlüsselbundfreigabe"),
        L10n.tr("Matter-Einrichtungsdaten zulassen"),
        L10n.tr("Per MDM verwaltete zugeordnete Domains"),
        L10n.tr("Mediengeräte erkennen"),
        L10n.tr("Zusammenarbeit in Nachrichten"),
        L10n.tr("Installation bei Bedarf"),
        L10n.tr("Sprechfunk"),
        L10n.tr("Sensible Inhalte analysieren"),
        L10n.tr("Mit dir geteilt"),
        L10n.tr("Eingelegte SIM für Mobilfunkanbieter"),
        L10n.tr("Profil für räumliches Audio"),
        L10n.tr("Dauerhafte Ausführung"),
        L10n.tr("Zeitkritische Mitteilungen"),
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
        .alert(L10n.tr("Aktion im Apple-Developer-Konto erforderlich"), isPresented: $showProgramLicenseAlert) {
            Button(L10n.tr("Apple-Developer-Konto öffnen")) {
                NSWorkspace.shared.open(Self.appleDeveloperAccountURL)
            }
            Button(L10n.tr("Schließen"), role: .cancel) {}
        } message: {
            Text(programLicenseAlertMessage)
        }
    }

    // MARK: - Phase 1: Form

    @ViewBuilder
    private var formContent: some View {
        BlitzSetupHeader(L10n.tr("Neue App einrichten"), subtitle: L10n.tr("Bereite einen separaten Store-Eintrag für dieses Veröffentlichungsziel vor. Für eine weitere Plattform derselben App verwende die Veröffentlichungsziele und den bestehenden Store-Eintrag."))

        Divider()

        if let error {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
            BlitzSetupField(L10n.tr("Bundle-ID"), hint: L10n.tr("Technische Kennung mit unveränderter Groß- und Kleinschreibung. Nach der Registrierung lässt sie sich nicht ändern.")) {
                TextField(L10n.tr("org.beispiel.MeineApp"), text: $bundleIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .accessibilityLabel(L10n.tr("Bundle-ID"))
            }
            BlitzSetupField(L10n.tr("App-Store-Name"), hint: L10n.tr("Öffentlicher Name mit 2–30 Zeichen, unabhängig von der technischen Kennung.")) {
                TextField(L10n.tr("Meine App"), text: Binding(
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
                .accessibilityLabel(L10n.tr("App-Store-Name"))
            }
            BlitzSetupField("SKU", hint: L10n.tr("Dauerhafte interne Kennung: Buchstaben, Zahlen, Punkte, Bindestriche und Unterstriche; keine Leerzeichen.")) {
                TextField(L10n.tr("MeineApp-\(effectivePlatform.rawValue)"), text: $sku)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("SKU")
            }
            BlitzSetupField(L10n.tr("Hauptsprache"), hint: L10n.tr("Exakter Sprachcode, zum Beispiel de-DE oder en-US.")) {
                TextField("de-DE", text: $primaryLocale)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.tr("Hauptsprache"))
            }
            BlitzSetupField(L10n.tr("Plattform")) {
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
            Text(L10n.tr("App-Funktionen"))
                .font(.callout.weight(.medium))
            Text(L10n.tr("Wähle die benötigten Funktionen. Weitere lassen sich später im Apple-Developer-Portal aktivieren."))
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
                    Text(L10n.tr("Weitere Funktionen (\(Self.portalOnlyCapabilities.count))"))
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
                        Text(L10n.tr("Diese Funktionen aktivierst du manuell im "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        + Text(LocalizedStringKey(L10n.tr("[Developer-Portal](https://developer.apple.com/account/resources/identifiers/list).")))
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
            Button(L10n.tr("Bundle-ID registrieren")) {
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
        BlitzSetupHeader(L10n.tr("Store-Eintrag anlegen"), subtitle: L10n.tr("Die Bundle-ID ist registriert. Lege jetzt die App mit den bestätigten Angaben in App Store Connect an."))

        VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
            BlitzSetupField(L10n.tr("Bundle-ID")) {
                Text(createdBundleId)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let identity = creationContext?.identity {
                BlitzSetupField(L10n.tr("App-Store-Name")) {
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
                Label(L10n.tr("Aktivierte App-Funktionen: \(capabilitiesEnabled)"), systemImage: "checkmark.circle")
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
                    Label(L10n.tr("Im bestehenden Chat fortsetzen"), systemImage: "doc.on.clipboard")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderedProminent)

                if copiedCreationHandoff {
                    Text(L10n.tr("Auftrag kopiert. Im Entwicklungs-Chat einfügen, um genau diese bestätigte App anzulegen."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button {
                    launchClaudeCodeForAppCreate(bundleId: createdBundleId, inExistingChat: false)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text(L10n.tr("Im Blitz-Terminal starten"))
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
                        Text(L10n.tr("App Store Connect öffnen"))
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
                            Text(L10n.tr("Anleitung zur manuellen Einrichtung"))
                                .font(.callout.weight(.medium))
                        }
                        .foregroundStyle(.blue)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showCreateInstructions {
                        VStack(alignment: .leading, spacing: 8) {
                            createInstructionStep(1, L10n.tr("Öffne **[App Store Connect](https://appstoreconnect.apple.com/apps)** und klicke auf **+**."))
                            createInstructionStep(2, L10n.tr("Wähle **Neue App**."))
                            createInstructionStep(3, L10n.tr("Wähle Plattform und Hauptsprache wie oben bestätigt."))
                            createInstructionStep(4, L10n.tr("Übernimm den bestätigten App-Store-Namen und wähle die registrierte Bundle-ID."))
                            createInstructionStep(5, L10n.tr("Übernimm die bestätigte **SKU**."))
                            createInstructionStep(6, L10n.tr("Klicke auf **Erstellen**."))
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Store-Eintrag bereits angelegt?"))
                .font(.callout.weight(.medium))

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BlitzFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                Button(L10n.tr("Angaben bearbeiten")) {
                    goBackToBundleRegistrationForm()
                }
                .buttonStyle(.bordered)

                Button(L10n.tr("Store-Eintrag prüfen")) {
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
            Text(L10n.tr("Store-Eintrag wird geprüft …"))
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
        progressMessage = L10n.tr("Bundle-ID und ausgewählte App-Funktionen werden registriert …")
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
                        userInfo: [NSLocalizedDescriptionKey: L10n.tr("Der Auftrag konnte nicht in die Zwischenablage kopiert werden.")])
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
    private func createInstructionStep(_ number: Int, _ text: String) -> some View {
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

    private func presentProgramLicenseAgreementAlert(_ error: ASCError) {
        programLicenseAlertMessage = error.programLicenseAgreementMessage + L10n.tr("\n\nÖffne https://developer.apple.com/account und bestätige dort die aktuelle Vereinbarung. Versuche es anschließend erneut.")
        showProgramLicenseAlert = true
    }

    private static let appleDeveloperAccountURL = URL(string: "https://developer.apple.com/account")!
}
