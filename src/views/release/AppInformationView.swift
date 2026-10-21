import SwiftUI

struct AppInformationView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    @FocusState private var focusedField: String?

    // Localized app-information fields
    @State private var title: String = ""
    @State private var subtitle: String = ""
    @State private var descriptionText: String = ""
    @State private var keywords: String = ""
    @State private var promotionalText: String = ""
    @State private var marketingUrl: String = ""
    @State private var supportUrl: String = ""
    @State private var whatsNew: String = ""
    @State private var privacyPolicyUrl: String = ""

    // Non-localized app-information fields
    @State private var copyright: String = ""
    @State private var primaryCategory: String = ""
    @State private var contentRights: String = ""
    @State private var teamId: String = ""

    @State private var isSaving = false
    @State private var suppressAutomaticWrites = false
    @State private var showAdvanced = false
    @State private var populatedText: [String] = []
    @State private var formRevision: UUID?
    @State private var formVersionID: String?
    @State private var formLocale = ""

    private var isCurrentForm: Bool {
        formRevision == asc.projectRevision && formVersionID == asc.selectedVersion?.id && formLocale == currentLocale
    }

    private var textValues: [String] {
        [title, subtitle, descriptionText, keywords, promotionalText, marketingUrl, supportUrl, whatsNew, privacyPolicyUrl]
    }

    private var mayRefreshFields: Bool {
        focusedField == nil && !isSaving && (populatedText.isEmpty || textValues == populatedText)
    }

    private var currentLocale: String {
        asc.activeAppInformationLocale() ?? ""
    }

    private var selectedVersionBinding: Binding<String> {
        Binding(
            get: { asc.selectedVersion?.id ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                asc.prepareForVersionSelection(newValue)
                Task {
                    await asc.refreshTabData(.appInformation)
                    populateCurrentFields()
                    populateDetailsFields()
                }
            }
        )
    }

    private var selectedLocaleBinding: Binding<String> {
        Binding(
            get: { currentLocale },
            set: { newValue in
                asc.selectedAppInformationLocale = newValue
                populateCurrentFields()
            }
        )
    }

    private static let categories: [(String, String)] = [
        ("GAMES", "Games"),
        ("UTILITIES", "Utilities"),
        ("PRODUCTIVITY", "Productivity"),
        ("SOCIAL_NETWORKING", "Social Networking"),
        ("PHOTO_AND_VIDEO", "Photo & Video"),
        ("MUSIC", "Music"),
        ("TRAVEL", "Travel"),
        ("SPORTS", "Sports"),
        ("HEALTH_AND_FITNESS", "Health & Fitness"),
        ("EDUCATION", "Education"),
        ("BUSINESS", "Business"),
        ("FINANCE", "Finance"),
        ("NEWS", "News"),
        ("FOOD_AND_DRINK", "Food & Drink"),
        ("LIFESTYLE", "Lifestyle"),
        ("SHOPPING", "Shopping"),
        ("ENTERTAINMENT", "Entertainment"),
        ("REFERENCE", "Reference"),
        ("MEDICAL", "Medical"),
        ("NAVIGATION", "Navigation"),
        ("WEATHER", "Weather"),
        ("DEVELOPER_TOOLS", "Developer Tools"),
    ]

    private static let contentRightsOptions: [(String, String)] = [
        ("DOES_NOT_USE_THIRD_PARTY_CONTENT", "Does Not Use Third-Party Content"),
        ("USES_THIRD_PARTY_CONTENT", "Uses Third-Party Content"),
    ]

    var body: some View {
        ASCCredentialGate(
            appState: appState,
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(appState: appState, asc: asc, tab: .appInformation, platform: appState.activeProject?.platform ?? .iOS, allowWithoutLocalProject: true) {
                appInformationContent
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            await asc.restoreTabCacheIfNeeded(.appInformation)
            guard !Task.isCancelled else { return }
            populateCurrentFields()
            populateDetailsFields()
            applyPendingValues()
            await asc.ensureTabData(.appInformation)
            guard !Task.isCancelled, mayRefreshFields else { return }
            populateCurrentFields()
            populateDetailsFields()
            applyPendingValues()
        }
        .onChange(of: asc.selectedAppInformationLocale) { _, _ in
            guard mayRefreshFields else { return }
            populateCurrentFields()
        }
        .onChange(of: asc.isTabLoading(.appInformation)) { wasLoading, isLoading in
            guard wasLoading, !isLoading else { return }
            guard mayRefreshFields else { return }
            populateCurrentFields()
            populateDetailsFields()
        }
        .onChange(of: asc.appInfo?.primaryCategoryId) { _, _ in if mayRefreshFields { populateDetailsFields() } }
        .onChange(of: asc.app?.contentRightsDeclaration) { _, _ in if mayRefreshFields { populateDetailsFields() } }
        .onDisappear {
            Task { await flushChanges() }
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var appInformationContent: some View {
        let locales = asc.localizations
        let current = asc.appInformationLocalization(locale: currentLocale)
        let isLoading = asc.isTabLoading(.appInformation)

        VStack(spacing: 0) {
            // Toolbar
            if asc.app != nil {
                ASCVersionPickerBar(
                    asc: asc,
                    selection: selectedVersionBinding,
                    appStoreURL: asc.app.flatMap { URL(string: "https://appstoreconnect.apple.com/apps/\($0.id)/appstore") },
                    refreshTab: .appInformation,
                    refreshHelpText: "Refresh app information"
                ) {
                    if !locales.isEmpty {
                        Picker("Locale", selection: selectedLocaleBinding) {
                            ForEach(locales) { loc in
                                Text(loc.attributes.locale).tag(loc.attributes.locale)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityLabel("Locale")
                        .help("Language of the store listing")
                        .frame(width: 110, alignment: .leading)
                    }
                    if isSaving {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Saving…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .blitzToolbar()
            }

            Divider()

            if !asc.canEditField("description") || !asc.canEditField("title") {
                Label("Gesperrte Angaben sind schreibgeschützt. Werbetext und Copyright bleiben bearbeitbar. Für andere Änderungen eine bearbeitbare Version auswählen.", systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, BlitzLayout.pageInset)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if current != nil {
                GeometryReader { geometry in
                    let usesColumns = geometry.size.width >= 800
                    ScrollView {
                        VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                            if let app = asc.app {
                                Text(app.name)
                                    .font(BlitzLayout.pageTitle)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            let columns = usesColumns
                                ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                                : AnyLayout(VStackLayout(alignment: .leading, spacing: BlitzLayout.sectionSpacing))
                            columns {
                                localizedContentFields
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                categoryAndLinks
                                    .frame(width: usesColumns ? 280 : nil)
                                    .frame(maxWidth: usesColumns ? nil : .infinity, alignment: .leading)
                            }
                            advancedSection(isLoading: isLoading)
                        }
                        .blitzPagePadding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if asc.localizations.isEmpty {
                if isLoading {
                    ASCTabLoadingPlaceholder(
                        title: "Loading App Information",
                        message: "Fetching localizations and app metadata."
                    )
                } else {
                    ContentUnavailableView(
                        "No Localizations",
                        systemImage: "text.page",
                        description: Text("No localizations found for the latest version.")
                    )
                    .padding(.top, 60)
                }
            }
        }
        .onChange(of: asc.pendingFormVersion) { _, _ in
            applyPendingValues()
        }
        .onChange(of: focusedField) { oldField, _ in
            if let oldField {
                // Non-localized fields save through separate ASC resources.
                if oldField == "copyright", !copyright.isEmpty, copyright != asc.selectedVersion?.attributes.copyright {
                    Task {
                        guard isCurrentForm else { return }
                        isSaving = true
                        await asc.updateAppInfoField("copyright", value: copyright)
                        isSaving = false
                    }
                } else if oldField == "teamId" {
                    saveTeamId()
                } else {
                    Task { await saveField(oldField) }
                }
            }
        }
    }

    private var localizedContentFields: some View {
        VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
            Text("Store Listing")
                .font(BlitzLayout.sectionTitle)
                .foregroundStyle(.secondary)
            editableField("Name", text: $title, fieldKey: "title", maxChars: 30)
            editableField("Subtitle", text: $subtitle, fieldKey: "subtitle", maxChars: 30)
            editableMultilineField("Description", text: $descriptionText, fieldKey: "description", maxChars: 4000)
            editableField("Keywords", text: $keywords, fieldKey: "keywords", maxChars: 100)
            editableMultilineField("Promotional Text", text: $promotionalText, fieldKey: "promotionalText", maxChars: 170)
            editableMultilineField("What's New", text: $whatsNew, fieldKey: "whatsNew")
        }
    }

    private var categoryAndLinks: some View {
        VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
            Text("Category & Links")
                .font(BlitzLayout.sectionTitle)
                .foregroundStyle(.secondary)
            // Primary Category
            VStack(alignment: .leading, spacing: 6) {
                Text("Primary Category")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $primaryCategory) {
                    Text("Select…").tag("")
                    ForEach(Self.categories, id: \.0) { id, label in
                        Text(label).tag(id)
                    }
                }
                .labelsHidden()
                .disabled(!asc.canEditField("primaryCategory"))
                .onChange(of: primaryCategory) { _, newValue in
                    guard !suppressAutomaticWrites, isCurrentForm else { return }
                    guard !newValue.isEmpty else { return }
                    guard newValue != asc.appInfo?.primaryCategoryId else { return }
                    Task {
                        guard isCurrentForm else { return }
                        isSaving = true
                        await asc.updateAppInfoField("primaryCategory", value: newValue)
                        isSaving = false
                    }
                }
            }

            // Content Rights
            VStack(alignment: .leading, spacing: 6) {
                Text("Content Rights")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $contentRights) {
                    Text("Select…").tag("")
                    ForEach(Self.contentRightsOptions, id: \.0) { id, label in
                        Text(label).tag(id)
                    }
                }
                .labelsHidden()
                .disabled(!asc.canEditField("contentRightsDeclaration"))
                .onChange(of: contentRights) { _, newValue in
                    guard !suppressAutomaticWrites, isCurrentForm else { return }
                    guard !newValue.isEmpty else { return }
                    guard newValue != asc.app?.contentRightsDeclaration else { return }
                    Task {
                        guard isCurrentForm else { return }
                        isSaving = true
                        await asc.updateAppInfoField("contentRightsDeclaration", value: newValue)
                        isSaving = false
                    }
                }
            }

            // Copyright
            editableField("Copyright", text: $copyright, fieldKey: "copyright")

            Divider()

            editableField("Privacy Policy URL", text: $privacyPolicyUrl, fieldKey: "privacyPolicyUrl")
            editableField("Support URL", text: $supportUrl, fieldKey: "supportUrl")
            editableField("Marketing URL", text: $marketingUrl, fieldKey: "marketingUrl")
        }
    }

    // MARK: - Advanced Section

    @ViewBuilder
    private func advancedSection(isLoading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAdvanced.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Text("Advanced")
                        .font(.callout.weight(.medium))
                    Spacer()
                }
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 0) {
                    // App Identity (read-only details)
                    advancedSectionHeader("App Identity")

                    if let app = asc.app {
                        Group {
                            InfoRow(label: "App ID", value: app.id)
                            Divider().opacity(0.5)
                            InfoRow(label: "Bundle ID", value: app.bundleId)
                            if let locale = app.primaryLocale {
                                Divider().opacity(0.5)
                                InfoRow(label: "Primary Locale", value: locale)
                            }
                            if let vendor = app.vendorNumber {
                                Divider().opacity(0.5)
                                InfoRow(label: "Vendor Number", value: vendor)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }

                    // Version Information
                    advancedSectionHeader("Version Information")
                        .padding(.top, 16)

                    if asc.appStoreVersions.isEmpty {
                        if isLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading version information…")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                        } else {
                            Text("No versions found")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 8)
                        }
                    } else {
                        ForEach(Array(asc.appStoreVersions.prefix(5).enumerated()), id: \.element.id) { idx, version in
                            BlitzFlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
                                Text(version.attributes.versionString)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                Text(version.attributes.releaseType ?? "—")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                                Text(version.attributes.appStoreState ?? "—")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                if let date = version.attributes.createdDate {
                                    Text(ascShortDate(date))
                                        .font(.caption)
                                        .foregroundStyle(.quaternary)
                                }
                            }
                            .padding(.vertical, 8)
                            if idx < min(4, asc.appStoreVersions.count - 1) {
                                Divider().opacity(0.5)
                            }
                        }
                    }

                    // Project Settings
                    advancedSectionHeader("Project Settings")
                        .padding(.top, 16)

                    if let project = appState.activeProject {
                        Group {
                            InfoRow(label: "Project Name", value: project.name)
                            Divider().opacity(0.5)
                            InfoRow(label: "Project Type", value: project.type.rawValue)
                            if let bid = project.metadata.bundleIdentifier {
                                Divider().opacity(0.5)
                                InfoRow(label: "Bundle ID (local)", value: bid)
                            }
                        }
                        .foregroundStyle(.secondary)

                        ProjectBundleIDSelectorView(
                            appState: appState,
                            asc: asc,
                            tab: .appInformation,
                            platform: project.platform,
                            subtitle: "Change which local bundle ID this project uses when loading App Store Connect data.",
                            standalone: false
                        )
                    }

                    // Build Signing
                    advancedSectionHeader("Build Signing")
                        .padding(.top, 16)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Team ID")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.tertiary)
                            TextField("e.g. 4GS43493GL", text: $teamId)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: "teamId")
                                .fontDesign(.monospaced)
                        }

                        if let project = appState.activeProject {
                            let signingState = loadSigningState(bundleId: project.metadata.bundleIdentifier ?? "")
                            if signingState.certificateId != nil || signingState.profileUUID != nil {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let certId = signingState.certificateId {
                                        HStack(spacing: 6) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green.opacity(0.6))
                                                .font(.callout)
                                            Text("Distribution Certificate")
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text(certId)
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .fontDesign(.monospaced)
                                                .lineLimit(1)
                                        }
                                    }
                                    if let uuid = signingState.profileUUID {
                                        HStack(spacing: 6) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green.opacity(0.6))
                                                .font(.callout)
                                            Text("Provisioning Profile")
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text(uuid)
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .fontDesign(.monospaced)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            } else {
                                Text("No signing configured. Run app_store_setup_signing or set a Team ID above.")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(BlitzLayout.cardInset)
                    .background(.background.secondary.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .transition(.opacity)
            }
        }
        .padding(.top, 8)
    }

    private func advancedSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.bottom, 6)
    }

    // MARK: - Field Population

    private func populateCurrentFields() {
        formRevision = asc.projectRevision
        formVersionID = asc.selectedVersion?.id
        formLocale = currentLocale
        populateFields(
            from: asc.appInformationLocalization(locale: currentLocale),
            infoLocalization: asc.appInfoLocalizationForLocale(currentLocale)
        )
    }

    private func populateFields(from loc: ASCVersionLocalization?, infoLocalization: ASCAppInfoLocalization?) {
        title = infoLocalization?.attributes.name ?? loc?.attributes.title ?? ""
        subtitle = infoLocalization?.attributes.subtitle ?? loc?.attributes.subtitle ?? ""
        privacyPolicyUrl = infoLocalization?.attributes.privacyPolicyUrl ?? ""
        descriptionText = loc?.attributes.description ?? ""
        keywords = loc?.attributes.keywords ?? ""
        promotionalText = loc?.attributes.promotionalText ?? ""
        marketingUrl = loc?.attributes.marketingUrl ?? ""
        supportUrl = loc?.attributes.supportUrl ?? ""
        whatsNew = loc?.attributes.whatsNew ?? ""
        populatedText = textValues
    }

    private func populateDetailsFields() {
        applyProgrammaticFieldUpdate {
            copyright = asc.selectedVersion?.attributes.copyright ?? ""
            primaryCategory = asc.appInfo?.primaryCategoryId ?? ""
            contentRights = asc.app?.contentRightsDeclaration ?? ""
            if let project = appState.activeProject {
                teamId = project.metadata.teamId ?? ""
            }
        }
    }

    private func applyPendingValues() {
        guard let pending = asc.pendingFormValues["appInformation"] else { return }

        applyProgrammaticFieldUpdate {
            for (field, value) in pending {
                switch field {
                case "title", "name": title = value
                case "subtitle": subtitle = value
                case "description": descriptionText = value
                case "keywords": keywords = value
                case "promotionalText": promotionalText = value
                case "marketingUrl": marketingUrl = value
                case "supportUrl": supportUrl = value
                case "whatsNew": whatsNew = value
                case "privacyPolicyUrl": privacyPolicyUrl = value
                case "copyright": copyright = value
                case "primaryCategory": primaryCategory = value
                case "contentRightsDeclaration": contentRights = value
                default: break
                }
            }
        }
    }

    private func applyProgrammaticFieldUpdate(_ update: () -> Void) {
        suppressAutomaticWrites = true
        update()
        DispatchQueue.main.async {
            suppressAutomaticWrites = false
        }
    }

    // MARK: - Saving

    private static let appInfoLocFields: Set<String> = ["title", "subtitle", "privacyPolicyUrl"]

    private func saveField(_ field: String) async {
        guard isCurrentForm, asc.canEditField(field) else { return }
        let value: String
        switch field {
        case "title": value = title
        case "subtitle": value = subtitle
        case "description": value = descriptionText
        case "keywords": value = keywords
        case "promotionalText": value = promotionalText
        case "marketingUrl": value = marketingUrl
        case "supportUrl": value = supportUrl
        case "whatsNew": value = whatsNew
        case "privacyPolicyUrl": value = privacyPolicyUrl
        default: return
        }

        let fields = ["title", "subtitle", "description", "keywords", "promotionalText", "marketingUrl", "supportUrl", "whatsNew", "privacyPolicyUrl"]
        guard let index = fields.firstIndex(of: field), populatedText.indices.contains(index), populatedText[index] != value else { return }
        let revision = formRevision, versionID = formVersionID, locale = formLocale
        isSaving = true
        if Self.appInfoLocFields.contains(field) {
            await asc.updateAppInfoLocalizationField(field, value: value, locale: currentLocale)
        } else {
            await asc.updateVersionLocalizationField(field, value: value, locale: currentLocale)
        }
        if asc.writeError == nil, isCurrentForm, formRevision == revision, formVersionID == versionID, formLocale == locale {
            populatedText[index] = value
        }
        isSaving = false
    }

    private func flushChanges() async {
        guard isCurrentForm else { return }
        if let focused = focusedField {
            if focused == "copyright" {
                if !copyright.isEmpty, copyright != asc.selectedVersion?.attributes.copyright {
                    await asc.updateAppInfoField("copyright", value: copyright)
                }
            } else if focused == "teamId" {
                saveTeamId()
            } else {
                await saveField(focused)
            }
        }
    }

    private func saveTeamId() {
        guard isCurrentForm else { return }
        let trimmed = teamId.trimmingCharacters(in: .whitespaces)
        guard let projectId = appState.activeProjectId else { return }
        let storage = ProjectStorage()
        guard var metadata = storage.readMetadata(projectId: projectId) else { return }
        metadata.teamId = trimmed.isEmpty ? nil : trimmed
        try? storage.writeMetadata(projectId: projectId, metadata: metadata)
    }

    private struct SigningStateSnapshot {
        var certificateId: String?
        var profileUUID: String?
    }

    private func loadSigningState(bundleId: String) -> SigningStateSnapshot {
        guard !bundleId.isEmpty else { return SigningStateSnapshot() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".blitz/signing/\(bundleId)/signing-state.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode(BuildPipelineService.SigningState.self, from: data) else {
            return SigningStateSnapshot()
        }
        return SigningStateSnapshot(certificateId: json.certificateId, profileUUID: json.profileUUID)
    }

    // MARK: - Field Helpers

    @ViewBuilder
    private func editableField(_ label: String, text: Binding<String>, fieldKey: String, maxChars: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                if let max = maxChars {
                    Spacer()
                    Text("\(text.wrappedValue.count)/\(max)")
                        .font(.caption)
                        .foregroundStyle(text.wrappedValue.count > max ? .red : .secondary)
                }
            }
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: fieldKey)
                .disabled(!asc.canEditField(fieldKey))
        }
    }

    @ViewBuilder
    private func editableMultilineField(_ label: String, text: Binding<String>, fieldKey: String, maxChars: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                if let max = maxChars {
                    Spacer()
                    Text("\(text.wrappedValue.count)/\(max)")
                        .font(.caption)
                        .foregroundStyle(text.wrappedValue.count > max ? .red : .secondary)
                }
            }
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .focused($focusedField, equals: fieldKey)
                .disabled(!asc.canEditField(fieldKey))
        }
    }
}
