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
    @State private var showProgramLicenseAlert = false
    @State private var programLicenseAlertMessage = ""

    // Capabilities supported by the ASC API (can be enabled automatically)
    private static let capabilities: [(type: String, name: String)] = [
        ("PUSH_NOTIFICATIONS", "Push Notifications"),
        ("IN_APP_PURCHASE", "In-App Purchase"),
        ("APPLE_ID_AUTH", "Sign in with Apple"),
        ("ICLOUD", "iCloud"),
        ("GAME_CENTER", "Game Center"),
        ("APPLE_PAY", "Apple Pay"),
        ("APP_GROUPS", "App Groups"),
        ("ASSOCIATED_DOMAINS", "Associated Domains"),
        ("HEALTHKIT", "HealthKit"),
        ("HOMEKIT", "HomeKit"),
        ("SIRIKIT", "Siri"),
        ("NFC_TAG_READING", "NFC Tag Reading"),
        ("WALLET", "Wallet"),
        ("MAPS", "Maps"),
        ("DATA_PROTECTION", "Data Protection"),
        ("AUTOFILL_CREDENTIAL_PROVIDER", "AutoFill Credential Provider"),
        ("ACCESS_WIFI_INFORMATION", "Access WiFi Information"),
        ("CLASSKIT", "ClassKit"),
        ("NETWORK_EXTENSIONS", "Network Extensions"),
        ("PERSONAL_VPN", "Personal VPN"),
        ("MULTIPATH", "Multipath"),
        ("HOT_SPOT", "Hotspot"),
        ("WIRELESS_ACCESSORY_CONFIGURATION", "Wireless Accessory"),
        ("INTER_APP_AUDIO", "Inter-App Audio"),
        ("NETWORK_CUSTOM_PROTOCOL", "Custom Network Protocol"),
        ("COREMEDIA_HLS_LOW_LATENCY", "HLS Low Latency"),
        ("SYSTEM_EXTENSION_INSTALL", "System Extension"),
        ("USER_MANAGEMENT", "User Management"),
    ]

    // Additional capabilities only configurable through the Apple Developer portal
    private static let portalOnlyCapabilities: [String] = [
        "5G Network Slicing",
        "App Attest",
        "Background Modes",
        "Communication Notifications",
        "Extended Virtual Addressing",
        "Family Controls",
        "Fonts",
        "Group Activities",
        "Head Pose",
        "HealthKit Estimate Recalibration",
        "HLS Interstitial Previews",
        "Increased Debugging Memory Limit",
        "Journaling Suggestions",
        "Keychain Sharing",
        "Matter Allow Setup Payload",
        "MDM Managed Associated Domains",
        "Media Device Discovery",
        "Messages Collaboration",
        "On Demand Install Capable",
        "Push to Talk",
        "Sensitive Content Analysis",
        "Shared with You",
        "SIM Inserted for Wireless Carriers",
        "Spatial Audio Profile",
        "Sustained Execution",
        "Time Sensitive Notifications",
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
                    VStack(alignment: .leading, spacing: 20) {
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
                    .padding(32)
                    .frame(maxWidth: 540, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { prefill(); applyFormRequest() }
                .onChange(of: asc.activeAppCreationFormRequest?.id) { _, _ in applyFormRequest() }
                .onChange(of: asc.loadedProjectId) { _, _ in resetForProjectChange() }
                .onChange(of: DashboardSummaryStore.accountKey(for: asc.credentials)) { _, _ in resetForProjectChange() }
            }
        }
        .alert("Action Required in Apple Developer", isPresented: $showProgramLicenseAlert) {
            Button("Open Apple Developer Account") {
                NSWorkspace.shared.open(Self.appleDeveloperAccountURL)
            }
            Button("Close", role: .cancel) {}
        } message: {
            Text(programLicenseAlertMessage)
        }
    }

    // MARK: - Phase 1: Form

    @ViewBuilder
    private var formContent: some View {
        // Header
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.title2)
                .foregroundStyle(.blue)
            Text("Register Your Bundle ID")
                .font(.title2.weight(.semibold))
        }
        Text("Create a bundle ID to connect your app to App Store Connect.")
            .font(.callout)
            .foregroundStyle(.secondary)

        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text("Bundle IDs cannot be changed once registered. Choose carefully.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider()

        if let error {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        // Fields
        VStack(alignment: .leading, spacing: 16) {
            labeledField("Bundle ID", hint: "The complete technical identifier, preserving capitalization and every dot") {
                TextField("org.example.MyApp", text: $bundleIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            HStack(spacing: 6) {
                Text("Bundle ID:")
                    .font(.callout.weight(.medium))
                Text(bundleIdPreview)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(isFormValid ? .primary : .secondary)
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 16) {
            labeledField("Public app name", hint: "The App Store name, 2–30 characters; independent of the technical identifier") {
                TextField("App Store name", text: Binding(
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
            }
            labeledField("SKU", hint: "Permanent identifier: letters, numbers, periods, hyphens and underscores; no spaces") {
                TextField("AppName-\(effectivePlatform.rawValue)", text: $sku)
                    .textFieldStyle(.roundedBorder)
            }
            labeledField("Primary language", hint: "Use the exact language code, for example de-DE or en-US") {
                TextField("en-US", text: $primaryLocale)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Platform: \(effectivePlatform.rawValue)")
                .font(.callout).foregroundStyle(.secondary)
            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.secondary)
            }
        }

        Divider()

        // Capabilities
        VStack(alignment: .leading, spacing: 8) {
            Text("Capabilities")
                .font(.callout.weight(.medium))
            Text("Select capabilities your app needs. You can add more later in the Apple Developer portal.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
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
                }
            }
            .padding(.top, 4)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAdditional.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showAdditional ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Additional Capabilities (\(Self.portalOnlyCapabilities.count))")
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
                        Text("These must be enabled manually in the ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        + Text("[Developer portal](https://developer.apple.com/account/resources/identifiers/list)")
                            .font(.caption)
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                        ForEach(Self.portalOnlyCapabilities, id: \.self) { name in
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.square")
                                    .font(.callout)
                                    .foregroundStyle(.quaternary)
                                Text(name)
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
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
            Button("Register Bundle ID") {
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
        // Success header
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            Text("Bundle ID Registered")
                .font(.title2.weight(.semibold))
        }

        VStack(alignment: .leading, spacing: 4) {
            Text(createdBundleId)
                .font(.system(.body, design: .monospaced))
            if capabilitiesEnabled > 0 {
                Text("\(capabilitiesEnabled) capability(ies) enabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let canonicalIdentifierNotice {
            Label(canonicalIdentifierNotice, systemImage: "info.circle")
                .font(.callout).foregroundStyle(.orange)
        }
        if let identity = creationContext?.identity {
            VStack(alignment: .leading, spacing: 5) {
                Text("App Store name: \(identity.appName)")
                Text("SKU: \(identity.sku)")
                Text("\(identity.platform.rawValue) · \(identity.primaryLocale)")
            }
            .font(.callout).textSelection(.enabled)
        }

        Divider()

        VStack(alignment: .leading, spacing: 12) {
            Text("Now create your app in App Store Connect.")
                .font(.callout)
            Text("Make sure to select the bundle ID you just registered:")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(createdBundleId)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .padding(8)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    launchClaudeCodeForAppCreate(bundleId: createdBundleId)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Setup with AI")
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
                        Text("Setup manually")
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
                            Text("How to create your app")
                                .font(.callout.weight(.medium))
                        }
                        .foregroundStyle(.blue)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showCreateInstructions {
                        VStack(alignment: .leading, spacing: 8) {
                            createInstructionStep(1, "Go to **[App Store Connect](https://appstoreconnect.apple.com/apps)** and click the **+** button")
                            createInstructionStep(2, "Select **New App**")
                            createInstructionStep(3, "Choose **\(creationContext?.identity.platform.rawValue ?? "")** and primary language **\(creationContext?.identity.primaryLocale ?? "")**")
                            createInstructionStep(4, "Enter the app name **\(createdAppName)** and select the **Bundle ID** you just registered: **\(createdBundleId)**")
                            createInstructionStep(5, "Use the confirmed **SKU**: **\(creationContext?.identity.sku ?? "")**")
                            createInstructionStep(6, "Click **Create**")
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 12) {
            Text("Did you create your app?")
                .font(.callout.weight(.medium))

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Back") {
                    goBackToBundleRegistrationForm()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Confirm") {
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
            Text("Checking App Store Connect\u{2026}")
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
        sku = "\(metadata.name)-\(effectivePlatform.rawValue)"
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
        progressMessage = "Registering bundle ID and selected capabilities…"
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
                    projectId: context.projectId, operationId: context.operationId.uuidString)
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

    private func launchClaudeCodeForAppCreate(bundleId: String) {
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
            let identityDirectory = projectDir.appendingPathComponent(".blitz", isDirectory: true)
            try FileManager.default.createDirectory(at: identityDirectory, withIntermediateDirectories: true)
            let identityFile = identityDirectory.appendingPathComponent("app-creation-\(context.operationId.uuidString).json")
            let identity = context.identity
            let values: [String: String] = ["appName": identity.appName, "bundleId": identity.bundleId,
                "sku": identity.sku, "platform": identity.platform.rawValue, "primaryLocale": identity.primaryLocale,
                "projectId": context.projectId, "operationId": context.operationId.uuidString,
                "expectedIssuerId": context.expectedIssuerId, "expectedKeyId": context.expectedKeyId]
            try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                .write(to: identityFile, options: .atomic)
            let prompt = try AppCreationAgentPrompt.make(identityFile: identityFile)
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

    @ViewBuilder
    private func labeledField<F: View>(_ label: String, hint: String, @ViewBuilder field: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout.weight(.medium))
            field()
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func presentProgramLicenseAgreementAlert(_ error: ASCError) {
        programLicenseAlertMessage = error.programLicenseAgreementMessage + "\n\nOpen https://developer.apple.com/account and accept the latest agreement, then retry."
        showProgramLicenseAlert = true
    }

    private static let appleDeveloperAccountURL = URL(string: "https://developer.apple.com/account")!
}
