import SwiftUI

struct ReviewView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }

    @State private var ageRatingExpanded = false
    @State private var contactExpanded = true
    @State private var isSavingAgeRating = false
    @State private var isSavingContact = false

    @State private var ageRatingDraft = ASCAgeRatingDeclaration.Attributes()

    // Review contact fields
    @State private var contactFirstName = ""
    @State private var contactLastName = ""
    @State private var contactEmail = ""
    @State private var contactPhone = ""
    @State private var contactNotes = ""
    @State private var demoRequired = false
    @State private var demoName = ""
    @State private var demoPassword = ""
    @FocusState private var contactFocused: String?

    // Build & Compliance
    @State private var selectedBuild = ""
    @State private var usesEncryption = false

    private let threeLevels = ["NONE", "INFREQUENT_OR_MILD", "FREQUENT_OR_INTENSE"]

    private var contactRequiredFieldsFilled: Bool {
        !contactFirstName.isEmpty && !contactLastName.isEmpty
            && !contactEmail.isEmpty && !contactPhone.isEmpty
    }

    private var selectedVersionBinding: Binding<String> {
        Binding(
            get: { asc.selectedVersion?.id ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                asc.prepareForVersionSelection(newValue)
                Task { await asc.refreshTabData(.review) }
            }
        )
    }

    var body: some View {
        ASCCredentialGate(
            appState: appState,
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(appState: appState, asc: asc, tab: .review, platform: appState.activeProject?.platform ?? .iOS, allowWithoutLocalProject: true) {
                reviewContent
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            await asc.ensureTabData(.review)
        }
        .onChange(of: asc.releaseVersions.map(\.id)) { _, _ in
            guard let appId = asc.app?.id else { return }
            let targetVersion = asc.selectedVersion
                ?? asc.currentUpdateVersion
                ?? asc.feedbackDisplayVersion(from: asc.releaseVersions)
            asc.loadCachedFeedback(appId: appId, versionString: targetVersion?.attributes.versionString)
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        let selectedVersion = asc.selectedVersion
        let rejectionCardVersion = asc.rejectionCardVersionForSelectedVersion(
            from: asc.releaseVersions
        )
        let isLoading = asc.isTabLoading(.review)

        VStack(spacing: 0) {
            if asc.app != nil {
                ASCVersionPickerBar(
                    asc: asc,
                    selection: selectedVersionBinding,
                    appStoreURL: asc.app.flatMap { URL(string: "https://appstoreconnect.apple.com/apps/\($0.id)/distribution/reviewsubmissions") },
                    refreshTab: .review,
                    refreshHelpText: L10n.tr("Prüfungsdaten aktualisieren")
                )
                .blitzToolbar()
            }

            Divider()

        ScrollView {
            VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                // Current version status card
                if let version = selectedVersion {
                    VStack(alignment: .leading, spacing: 12) {
                        BlitzFlowLayout(horizontalSpacing: 12, verticalSpacing: 8) {
                            Text("Version \(version.attributes.versionString)")
                                .font(BlitzLayout.pageTitle)
                            ASCVersionStatusBadges(asc: asc, version: version)
                        }
                        if let date = version.attributes.createdDate {
                            Text(L10n.tr("Erstellt am \(ascShortDate(date))"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BlitzLayout.cardInset)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    ASCReviewProgressView(progress: ASCReviewProgress(asc: asc, version: version))

                    // Rejection detail — shown when rejected, or when cached feedback persists after re-submission
                    if let rejectionCardVersion,
                       rejectionCardVersion.id == version.id {
                        RejectionCardView(asc: asc, version: rejectionCardVersion) { EmptyView() }
                    }
                }

                // Age Rating
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation { ageRatingExpanded.toggle() }
                    } label: {
                        HStack {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(ageRatingExpanded ? 90 : 0))
                                .animation(.easeInOut(duration: 0.15), value: ageRatingExpanded)
                            Text(L10n.tr("Altersfreigabe"))
                                .font(BlitzLayout.sectionTitle)
                            Spacer()
                            if asc.ageRatingIsConfigured {
                                Text(L10n.tr("Eingerichtet"))
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundStyle(.green)
                                    .clipShape(Capsule())
                            } else if isLoading {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.tr("Wird geladen …"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text(L10n.tr("Nicht festgelegt"))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if ageRatingExpanded {
                        ageRatingForm
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(BlitzLayout.cardInset)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Review Contact
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation { contactExpanded.toggle() }
                    } label: {
                        HStack {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(contactExpanded ? 90 : 0))
                                .animation(.easeInOut(duration: 0.15), value: contactExpanded)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.tr("Kontakt für die App-Prüfung"))
                                    .font(BlitzLayout.sectionTitle)
                                if let rd = asc.reviewDetail,
                                   rd.attributes.contactFirstName != nil {
                                    Text("\(rd.attributes.contactFirstName ?? "") \(rd.attributes.contactLastName ?? "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else if isLoading {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text(L10n.tr("Wird geladen …"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(L10n.tr("Nicht eingerichtet"))
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if contactExpanded {
                        reviewContactForm
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(BlitzLayout.cardInset)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Build & Compliance
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.tr("Build und Exportbestimmungen"))
                        .font(BlitzLayout.sectionTitle)

                    if asc.builds.isEmpty {
                        if isLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(L10n.tr("Builds und Prüfungsverlauf werden geladen …"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(L10n.tr("Keine Builds verfügbar. Lade einen Build über Xcode oder Transporter hoch."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Build", selection: $selectedBuild) {
                            Text(L10n.tr("Build auswählen …")).tag("")
                            ForEach(asc.builds.filter { $0.attributes.processingState == "VALID" }) { build in
                                Text("\(build.attributes.version) (\(ascShortDate(build.attributes.uploadedDate ?? "")))")
                                    .tag(build.id)
                            }
                        }

                        Toggle(L10n.tr("Verwendet nicht ausgenommene Verschlüsselung"), isOn: $usesEncryption)
                            .onChange(of: usesEncryption) { _, newValue in
                                guard !selectedBuild.isEmpty else { return }
                                Task {
                                    try? await asc.service?.patchBuildEncryption(
                                        buildId: selectedBuild,
                                        usesNonExemptEncryption: newValue
                                    )
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(BlitzLayout.cardInset)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // All versions
                if asc.releaseVersions.count > 1 {
                    Text(L10n.tr("Alle Versionen"))
                        .font(BlitzLayout.sectionTitle)

                    VStack(spacing: 0) {
                        ForEach(Array(asc.releaseVersions.enumerated()), id: \.element.id) { idx, version in
                            BlitzFlowLayout(horizontalSpacing: 12, verticalSpacing: 6) {
                                Text(version.attributes.versionString)
                                    .font(.body.weight(.medium))
                                ASCVersionStatusBadges(asc: asc, version: version)
                                if ASCReleaseStatus.normalize(version.attributes.effectiveState) != "REJECTED",
                                   wasVersionPreviouslyRejected(version) {
                                    Text(L10n.tr("Zuvor abgelehnt"))
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.red.opacity(0.1))
                                        .foregroundStyle(.red)
                                        .clipShape(Capsule())
                                }
                                if let date = version.attributes.createdDate {
                                    Text(ascShortDate(date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            if idx < asc.releaseVersions.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .blitzPagePadding()
        }
        }
        .onAppear {
            populateAgeRating()
            populateContact()
            applyPendingValues()
            syncSelectedBuild()
        }
        .onChange(of: asc.ageRatingDeclaration) { _, _ in populateAgeRating() }
        .onChange(of: asc.reviewDetail?.id) { _, _ in populateContact() }
        .onChange(of: asc.pendingFormVersion) { _, _ in applyPendingValues() }
        .onChange(of: asc.builds.map(\.id)) { _, _ in syncSelectedBuild() }
        .onChange(of: asc.selectedVersionBuild?.id) { _, _ in syncSelectedBuild() }
        .onChange(of: contactFocused) { _, _ in
            // Don't auto-save contact — requires all required fields.
            // User saves explicitly via the "Kontakt speichern" button.
        }
    }

    // MARK: - Age Rating Form

    @ViewBuilder
    private var ageRatingForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !asc.canEditField("ageRating") {
                Label(L10n.tr("Die Altersfreigabe ist für diesen Apple-Status schreibgeschützt."), systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Group {
                Text(L10n.tr("Enthaltene Funktionen")).font(.callout.weight(.medium)).padding(.top, 8)
                ageRatingAnswer(L10n.tr("Glücksspiel"), selection: $ageRatingDraft.gambling)
                ageRatingAnswer(L10n.tr("Nachrichten und Chat"), selection: $ageRatingDraft.messagingAndChat)
                ageRatingAnswer(L10n.tr("Uneingeschränkter Internetzugang"), selection: $ageRatingDraft.unrestrictedWebAccess)
                ageRatingAnswer(L10n.tr("Nutzergenerierte Inhalte"), selection: $ageRatingDraft.userGeneratedContent)
                ageRatingAnswer(L10n.tr("Werbung"), selection: $ageRatingDraft.advertising)
                ageRatingAnswer(L10n.tr("Lootboxen"), selection: $ageRatingDraft.lootBox)
                ageRatingAnswer(L10n.tr("Gesundheits- und Wellnessthemen"), selection: $ageRatingDraft.healthOrWellnessTopics)
                ageRatingAnswer(L10n.tr("Kindersicherung"), selection: $ageRatingDraft.parentalControls)
                ageRatingAnswer(L10n.tr("Altersüberprüfung"), selection: $ageRatingDraft.ageAssurance)
            }

            ageRatingAnswer(L10n.tr("Soziale Medien"), selection: $ageRatingDraft.socialMedia)
            ageRatingAnswer(L10n.tr("Altersbeschränkte soziale Medien"), selection: $ageRatingDraft.socialMediaAgeRestricted)
            ageRatingAnswer(L10n.tr("Standortfreigabe"), selection: $ageRatingDraft.sharedLocation)
            ageRatingAnswer(L10n.tr("Dating und Beziehungen"), selection: $ageRatingDraft.datingAndRelationships)

            Divider()

            Group {
                Text(L10n.tr("Häufigkeit der Inhalte")).font(.callout.weight(.medium))
                threeLevelPicker(L10n.tr("Alkohol-, Tabak- oder Drogenkonsum"), selection: $ageRatingDraft.alcoholTobaccoOrDrugUseOrReferences)
                threeLevelPicker(L10n.tr("Wettbewerbe"), selection: $ageRatingDraft.contests)
                threeLevelPicker(L10n.tr("Simuliertes Glücksspiel"), selection: $ageRatingDraft.gamblingSimulated)
                threeLevelPicker(L10n.tr("Schusswaffen oder andere Waffen"), selection: $ageRatingDraft.gunsOrOtherWeapons)
                threeLevelPicker(L10n.tr("Horror- oder Angstthemen"), selection: $ageRatingDraft.horrorOrFearThemes)
                threeLevelPicker(L10n.tr("Erwachsenen- oder anzügliche Themen"), selection: $ageRatingDraft.matureOrSuggestiveThemes)
                threeLevelPicker(L10n.tr("Medizinische oder Behandlungsinformationen"), selection: $ageRatingDraft.medicalOrTreatmentInformation)
                threeLevelPicker(L10n.tr("Vulgäre Sprache oder derber Humor"), selection: $ageRatingDraft.profanityOrCrudeHumor)
            }

            Group {
                threeLevelPicker(L10n.tr("Explizite sexuelle Inhalte und Nacktheit"), selection: $ageRatingDraft.sexualContentGraphicAndNudity)
                threeLevelPicker(L10n.tr("Sexuelle Inhalte oder Nacktheit"), selection: $ageRatingDraft.sexualContentOrNudity)
                threeLevelPicker(L10n.tr("Gewalt in Zeichentrick oder Fantasy"), selection: $ageRatingDraft.violenceCartoonOrFantasy)
                threeLevelPicker(L10n.tr("Realistische Gewalt"), selection: $ageRatingDraft.violenceRealistic)
                threeLevelPicker(L10n.tr("Anhaltende, explizite oder sadistische Gewalt"), selection: $ageRatingDraft.violenceRealisticProlongedGraphicOrSadistic)
            }

            HStack {
                Spacer()
                Button(L10n.tr("Altersfreigabe speichern")) {
                    Task { await saveAgeRating() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingAgeRating || ageRatingChanges.isEmpty)

                if isSavingAgeRating {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 8)
        }
        .padding(.top, 8)
        .disabled(!asc.canEditField("ageRating"))
    }

    private func ageRatingAnswer(_ label: String, selection: Binding<Bool?>) -> some View {
        let picker = Picker(label, selection: selection) {
            if selection.wrappedValue == nil {
                Text(L10n.tr("Nicht beantwortet")).tag(nil as Bool?)
            }
            Text(L10n.tr("Ja")).tag(true as Bool?)
            Text(L10n.tr("Nein")).tag(false as Bool?)
        }
        .labelsHidden()
        .accessibilityLabel(label)

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(label).fixedSize()
                Spacer(minLength: 0)
                picker.fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label).fixedSize(horizontal: false, vertical: true)
                picker.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
    }

    private func threeLevelPicker(_ label: String, selection: Binding<String?>) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(label).fixedSize()
                Spacer(minLength: 0)
                frequencyPicker(selection: selection).frame(width: 220)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label).fixedSize(horizontal: false, vertical: true)
                frequencyPicker(selection: selection)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func frequencyPicker(selection: Binding<String?>) -> some View {
        Picker(L10n.tr("Häufigkeit"), selection: selection) {
            if let current = selection.wrappedValue {
                if !["NONE", "INFREQUENT_OR_MILD", "FREQUENT_OR_INTENSE"].contains(current) {
                    Text(current).tag(current as String?)
                }
            } else {
                Text(L10n.tr("Nicht beantwortet")).tag(nil as String?)
            }
            Text(L10n.tr("Keine")).tag("NONE" as String?)
            Text(L10n.tr("Selten oder schwach")).tag("INFREQUENT_OR_MILD" as String?)
            Text(L10n.tr("Häufig oder intensiv")).tag("FREQUENT_OR_INTENSE" as String?)
        }
        .labelsHidden()
    }

    // MARK: - Review Contact Form

    @ViewBuilder
    private var reviewContactForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Vorname")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    TextField(L10n.tr("Vorname"), text: $contactFirstName)
                        .textFieldStyle(.roundedBorder)
                        .focused($contactFocused, equals: "firstName")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Nachname")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    TextField(L10n.tr("Nachname"), text: $contactLastName)
                        .textFieldStyle(.roundedBorder)
                        .focused($contactFocused, equals: "lastName")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("E-Mail")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                TextField("email@example.com", text: $contactEmail)
                    .textFieldStyle(.roundedBorder)
                    .focused($contactFocused, equals: "email")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Telefon")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                TextField("+1 650 555 0100", text: $contactPhone)
                    .textFieldStyle(.roundedBorder)
                    .focused($contactFocused, equals: "phone")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Hinweise")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                TextEditor(text: $contactNotes)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .focused($contactFocused, equals: "notes")
            }

            Toggle(L10n.tr("Demokonto erforderlich"), isOn: $demoRequired)

            if demoRequired {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("Benutzername")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        TextField(L10n.tr("Demo-Benutzername"), text: $demoName)
                            .textFieldStyle(.roundedBorder)
                            .focused($contactFocused, equals: "demoName")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("Passwort")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        SecureField(L10n.tr("Demo-Passwort"), text: $demoPassword)
                            .textFieldStyle(.roundedBorder)
                            .focused($contactFocused, equals: "demoPassword")
                    }
                }
            }

            if let error = asc.writeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                if isSavingContact {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(L10n.tr("Wird gespeichert …")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(L10n.tr("Kontakt speichern")) {
                    Task { await saveContact() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingContact || !contactRequiredFieldsFilled)
            }
            .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    // MARK: - Data Population

    private func populateAgeRating() {
        ageRatingDraft = asc.ageRatingDeclaration?.attributes ?? .init()
    }

    private func populateContact() {
        guard let rd = asc.reviewDetail?.attributes else { return }
        contactFirstName = rd.contactFirstName ?? ""
        contactLastName = rd.contactLastName ?? ""
        contactEmail = rd.contactEmail ?? ""
        contactPhone = rd.contactPhone ?? ""
        contactNotes = rd.notes ?? ""
        demoRequired = rd.demoAccountRequired ?? false
        demoName = rd.demoAccountName ?? ""
        demoPassword = rd.demoAccountPassword ?? ""
    }

    private func applyPendingValues() {
        if let pending = asc.pendingFormValues["review.ageRating"] {
            for (field, path) in ASCAgeRatingDeclaration.Attributes.booleanFields {
                if let value = pending[field], let answer = Bool(value) { ageRatingDraft[keyPath: path] = answer }
            }
            for (field, path) in ASCAgeRatingDeclaration.Attributes.frequencyFields {
                if let value = pending[field] { ageRatingDraft[keyPath: path] = value }
            }
        }
        if let pending = asc.pendingFormValues["review.contact"] {
            for (field, value) in pending {
                switch field {
                case "contactFirstName": contactFirstName = value
                case "contactLastName": contactLastName = value
                case "contactEmail": contactEmail = value
                case "contactPhone": contactPhone = value
                case "notes": contactNotes = value
                case "demoAccountRequired": demoRequired = value == "true"
                case "demoAccountName": demoName = value
                case "demoAccountPassword": demoPassword = value
                default: break
                }
            }
        }
    }

    // MARK: - Save

    private var ageRatingChanges: [String: Any] {
        guard let saved = asc.ageRatingDeclaration?.attributes else { return [:] }
        return ageRatingDraft.changedAnswers(from: saved)
    }

    private func saveAgeRating() async {
        let changes = ageRatingChanges
        guard !changes.isEmpty else { return }
        isSavingAgeRating = true
        await asc.updateAgeRating(changes)
        isSavingAgeRating = false
    }

    private func saveContact() async {
        isSavingContact = true
        var attrs: [String: Any] = [
            "contactFirstName": contactFirstName,
            "contactLastName": contactLastName,
            "contactEmail": contactEmail,
            "contactPhone": contactPhone,
            "demoAccountRequired": demoRequired,
        ]
        if !contactNotes.isEmpty { attrs["notes"] = contactNotes }
        if demoRequired {
            attrs["demoAccountName"] = demoName
            attrs["demoAccountPassword"] = demoPassword
        }
        await asc.updateReviewContact(attrs)
        isSavingContact = false
    }

    // MARK: - UI Helpers

    /// Check if a version was previously rejected (has rejected submission items or cached feedback)
    private func wasVersionPreviouslyRejected(_ version: ASCAppStoreVersion) -> Bool {
        if asc.hasRejectedSubmissionHistory(forVersionId: version.id) {
            return true
        }
        if asc.hasIrisFeedback(for: version) {
            return true
        }
        return false
    }

    private func syncSelectedBuild() {
        if let attachedBuildId = asc.selectedVersionBuild?.id,
           asc.builds.contains(where: { $0.id == attachedBuildId }) {
            selectedBuild = attachedBuildId
            return
        }
        if !selectedBuild.isEmpty,
           asc.builds.contains(where: { $0.id == selectedBuild }) {
            return
        }
        selectedBuild = asc.builds.first(where: { $0.attributes.processingState == "VALID" })?.id
            ?? asc.builds.first?.id
            ?? ""
    }

}
