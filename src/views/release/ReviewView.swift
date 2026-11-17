import SwiftUI

struct ReviewView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }

    @State private var ageRatingExpanded = false
    @State private var contactExpanded = true
    @State private var isSavingAgeRating = false
    @State private var isSavingContact = false

    // Age Rating boolean fields
    @State private var arGambling = false
    @State private var arMessaging = false
    @State private var arWebAccess = false
    @State private var arUGC = false
    @State private var arAdvertising = false
    @State private var arLootBox = false
    @State private var arHealth = false
    @State private var arParental = false
    @State private var arAgeAssurance = false

    // Age Rating string fields (NONE / INFREQUENT_OR_MILD / FREQUENT_OR_INTENSE)
    @State private var arAlcohol = "NONE"
    @State private var arContests = "NONE"
    @State private var arGamblingSim = "NONE"
    @State private var arGuns = "NONE"
    @State private var arHorror = "NONE"
    @State private var arMature = "NONE"
    @State private var arMedical = "NONE"
    @State private var arProfanity = "NONE"
    @State private var arSexGraphic = "NONE"
    @State private var arSex = "NONE"
    @State private var arViolenceCartoon = "NONE"
    @State private var arViolenceRealistic = "NONE"
    @State private var arViolenceProlonged = "NONE"

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

                    // Rejection detail — shown when rejected, or when cached feedback persists after re-submission
                    if let rejectionCardVersion,
                       rejectionCardVersion.id == version.id {
                        RejectionCardView(asc: asc, version: rejectionCardVersion) {
                            Text(L10n.tr("Aktualisiere die Prüfungsangaben unten und reiche die Version anschließend erneut ein."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                            if asc.ageRatingDeclaration != nil {
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
        .onChange(of: asc.ageRatingDeclaration?.id) { _, _ in populateAgeRating() }
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
                Toggle(L10n.tr("Glücksspiel"), isOn: $arGambling)
                Toggle(L10n.tr("Nachrichten und Chat"), isOn: $arMessaging)
                Toggle(L10n.tr("Uneingeschränkter Internetzugang"), isOn: $arWebAccess)
                Toggle(L10n.tr("Nutzergenerierte Inhalte"), isOn: $arUGC)
                Toggle(L10n.tr("Werbung"), isOn: $arAdvertising)
                Toggle(L10n.tr("Lootboxen"), isOn: $arLootBox)
                Toggle(L10n.tr("Gesundheits- und Wellnessthemen"), isOn: $arHealth)
                Toggle(L10n.tr("Kindersicherung"), isOn: $arParental)
                Toggle(L10n.tr("Altersüberprüfung"), isOn: $arAgeAssurance)
            }

            Divider()

            Group {
                Text(L10n.tr("Häufigkeit der Inhalte")).font(.callout.weight(.medium))
                threeLevelPicker(L10n.tr("Alkohol-, Tabak- oder Drogenkonsum"), selection: $arAlcohol)
                threeLevelPicker(L10n.tr("Wettbewerbe"), selection: $arContests)
                threeLevelPicker(L10n.tr("Simuliertes Glücksspiel"), selection: $arGamblingSim)
                threeLevelPicker(L10n.tr("Schusswaffen oder andere Waffen"), selection: $arGuns)
                threeLevelPicker(L10n.tr("Horror- oder Angstthemen"), selection: $arHorror)
                threeLevelPicker(L10n.tr("Erwachsenen- oder anzügliche Themen"), selection: $arMature)
                threeLevelPicker(L10n.tr("Medizinische oder Behandlungsinformationen"), selection: $arMedical)
                threeLevelPicker(L10n.tr("Vulgäre Sprache oder derber Humor"), selection: $arProfanity)
            }

            Group {
                threeLevelPicker(L10n.tr("Explizite sexuelle Inhalte und Nacktheit"), selection: $arSexGraphic)
                threeLevelPicker(L10n.tr("Sexuelle Inhalte oder Nacktheit"), selection: $arSex)
                threeLevelPicker(L10n.tr("Gewalt in Zeichentrick oder Fantasy"), selection: $arViolenceCartoon)
                threeLevelPicker(L10n.tr("Realistische Gewalt"), selection: $arViolenceRealistic)
                threeLevelPicker(L10n.tr("Anhaltende, explizite oder sadistische Gewalt"), selection: $arViolenceProlonged)
            }

            HStack {
                Spacer()
                Button(L10n.tr("Altersfreigabe speichern")) {
                    Task { await saveAgeRating() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingAgeRating)

                if isSavingAgeRating {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 8)
        }
        .padding(.top, 8)
        .disabled(!asc.canEditField("ageRating"))
    }

    private func threeLevelPicker(_ label: String, selection: Binding<String>) -> some View {
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

    private func frequencyPicker(selection: Binding<String>) -> some View {
        Picker(L10n.tr("Häufigkeit"), selection: selection) {
            Text(L10n.tr("Keine")).tag("NONE")
            Text(L10n.tr("Selten oder schwach")).tag("INFREQUENT_OR_MILD")
            Text(L10n.tr("Häufig oder intensiv")).tag("FREQUENT_OR_INTENSE")
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
        guard let ar = asc.ageRatingDeclaration?.attributes else { return }
        arGambling = ar.gambling ?? false
        arMessaging = ar.messagingAndChat ?? false
        arWebAccess = ar.unrestrictedWebAccess ?? false
        arUGC = ar.userGeneratedContent ?? false
        arAdvertising = ar.advertising ?? false
        arLootBox = ar.lootBox ?? false
        arHealth = ar.healthOrWellnessTopics ?? false
        arParental = ar.parentalControls ?? false
        arAgeAssurance = ar.ageAssurance ?? false

        arAlcohol = ar.alcoholTobaccoOrDrugUseOrReferences ?? "NONE"
        arContests = ar.contests ?? "NONE"
        arGamblingSim = ar.gamblingSimulated ?? "NONE"
        arGuns = ar.gunsOrOtherWeapons ?? "NONE"
        arHorror = ar.horrorOrFearThemes ?? "NONE"
        arMature = ar.matureOrSuggestiveThemes ?? "NONE"
        arMedical = ar.medicalOrTreatmentInformation ?? "NONE"
        arProfanity = ar.profanityOrCrudeHumor ?? "NONE"
        arSexGraphic = ar.sexualContentGraphicAndNudity ?? "NONE"
        arSex = ar.sexualContentOrNudity ?? "NONE"
        arViolenceCartoon = ar.violenceCartoonOrFantasy ?? "NONE"
        arViolenceRealistic = ar.violenceRealistic ?? "NONE"
        arViolenceProlonged = ar.violenceRealisticProlongedGraphicOrSadistic ?? "NONE"
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
            for (field, value) in pending {
                switch field {
                case "gambling": arGambling = value == "true"
                case "messagingAndChat": arMessaging = value == "true"
                case "unrestrictedWebAccess": arWebAccess = value == "true"
                case "userGeneratedContent": arUGC = value == "true"
                case "advertising": arAdvertising = value == "true"
                case "lootBox": arLootBox = value == "true"
                case "healthOrWellnessTopics": arHealth = value == "true"
                case "parentalControls": arParental = value == "true"
                case "ageAssurance": arAgeAssurance = value == "true"
                case "alcoholTobaccoOrDrugUseOrReferences": arAlcohol = value
                case "contests": arContests = value
                case "gamblingSimulated": arGamblingSim = value
                case "gunsOrOtherWeapons": arGuns = value
                case "horrorOrFearThemes": arHorror = value
                case "matureOrSuggestiveThemes": arMature = value
                case "medicalOrTreatmentInformation": arMedical = value
                case "profanityOrCrudeHumor": arProfanity = value
                case "sexualContentGraphicAndNudity": arSexGraphic = value
                case "sexualContentOrNudity": arSex = value
                case "violenceCartoonOrFantasy": arViolenceCartoon = value
                case "violenceRealistic": arViolenceRealistic = value
                case "violenceRealisticProlongedGraphicOrSadistic": arViolenceProlonged = value
                default: break
                }
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

    private func saveAgeRating() async {
        isSavingAgeRating = true
        let attrs: [String: Any] = [
            "gambling": arGambling,
            "messagingAndChat": arMessaging,
            "unrestrictedWebAccess": arWebAccess,
            "userGeneratedContent": arUGC,
            "advertising": arAdvertising,
            "lootBox": arLootBox,
            "healthOrWellnessTopics": arHealth,
            "parentalControls": arParental,
            "ageAssurance": arAgeAssurance,
            "alcoholTobaccoOrDrugUseOrReferences": arAlcohol,
            "contests": arContests,
            "gamblingSimulated": arGamblingSim,
            "gunsOrOtherWeapons": arGuns,
            "horrorOrFearThemes": arHorror,
            "matureOrSuggestiveThemes": arMature,
            "medicalOrTreatmentInformation": arMedical,
            "profanityOrCrudeHumor": arProfanity,
            "sexualContentGraphicAndNudity": arSexGraphic,
            "sexualContentOrNudity": arSex,
            "violenceCartoonOrFantasy": arViolenceCartoon,
            "violenceRealistic": arViolenceRealistic,
            "violenceRealisticProlongedGraphicOrSadistic": arViolenceProlonged,
        ]
        await asc.updateAgeRating(attrs)
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
