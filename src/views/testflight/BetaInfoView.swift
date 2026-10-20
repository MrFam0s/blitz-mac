import SwiftUI

struct BetaInfoView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    @State private var selectedLocId: String = ""
    @State private var editDescription = ""
    @State private var editFeedbackEmail = ""
    @State private var editMarketingUrl = ""
    @State private var editPrivacyUrl = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveSuccess = false
    @State private var populatedValues: [String] = []
    @State private var formRevision: UUID?
    private var editValues: [String] { [editDescription, editFeedbackEmail, editMarketingUrl, editPrivacyUrl] }
    private var hasEdits: Bool { !populatedValues.isEmpty && editValues != populatedValues }

    var body: some View {
        ASCCredentialGate(
            appState: appState,
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(appState: appState, asc: asc, tab: .betaInfo, platform: appState.activeProject?.platform ?? .iOS, allowWithoutLocalProject: true) {
                betaInfoContent
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            await asc.restoreTabCacheIfNeeded(.betaInfo)
            guard !Task.isCancelled else { return }
            syncLocalization()
            await asc.ensureTabData(.betaInfo)
            guard !Task.isCancelled else { return }
            syncLocalization()
        }
        .onChange(of: asc.projectRevision) { _, _ in
            selectedLocId = ""
            populatedValues = []
            editDescription = ""
            editFeedbackEmail = ""
            editMarketingUrl = ""
            editPrivacyUrl = ""
            isSaving = false
            saveError = nil
            saveSuccess = false
            syncLocalization()
        }
        .onChange(of: asc.betaLocalizations) { _, _ in syncLocalization() }
    }

    private func syncLocalization() {
        guard formRevision != asc.projectRevision || (!hasEdits && !isSaving) else { return }
        if let current = asc.betaLocalizations.first(where: { $0.id == selectedLocId }) ?? asc.betaLocalizations.first {
            selectedLocId = current.id
            loadLocalization(current)
        }
    }

    @ViewBuilder
    private var betaInfoContent: some View {
        let locs = asc.betaLocalizations
        let current = locs.first { $0.id == selectedLocId } ?? locs.first

        VStack(spacing: 0) {
            // Locale picker toolbar
            HStack {
                if !locs.isEmpty {
                    Picker("Locale", selection: $selectedLocId) {
                        ForEach(locs) { loc in
                            Text(loc.attributes.locale).tag(loc.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isSaving)
                    .frame(width: 180)
                    .onChange(of: locs.count) { _, _ in
                        if selectedLocId.isEmpty, let first = asc.betaLocalizations.first {
                            selectedLocId = first.id
                            loadLocalization(first)
                        }
                    }
                    .onAppear {
                        if selectedLocId.isEmpty, let first = locs.first {
                            selectedLocId = first.id
                            loadLocalization(first)
                        }
                    }
                    .onChange(of: selectedLocId) { _, newId in
                        if let loc = locs.first(where: { $0.id == newId }) {
                            loadLocalization(loc)
                        }
                    }
                }
                Spacer()
                if saveSuccess {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                if let error = saveError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Button {
                    save(locId: current?.id ?? selectedLocId)
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || current == nil || formRevision != asc.projectRevision || !hasEdits)
                ASCTabRefreshButton(asc: asc, tab: .betaInfo, helpText: "Refresh beta info")
            }
            .blitzToolbar()

            Divider()

            if current == nil && !locs.isEmpty {
                ContentUnavailableView("Select a locale", systemImage: "doc.text")
            } else if locs.isEmpty {
                if asc.isTabLoading(.betaInfo) {
                    ASCTabLoadingPlaceholder(
                        title: "Loading Beta Info",
                        message: "Fetching beta app localizations and tester-facing copy."
                    )
                } else {
                    ContentUnavailableView(
                        "No Localizations",
                        systemImage: "doc.text",
                        description: Text("No beta app localizations found.")
                    )
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        editField("Beta Description",
                                  text: $editDescription,
                                  hint: "Describe what testers should focus on",
                                  multiline: true)

                        editField("Feedback Email",
                                  text: $editFeedbackEmail,
                                  hint: "Email for tester feedback")

                        editField("Marketing URL",
                                  text: $editMarketingUrl,
                                  hint: "https://example.com")

                        editField("Privacy Policy URL",
                                  text: $editPrivacyUrl,
                                  hint: "https://example.com/privacy")
                    }
                    .blitzPagePadding()
                }
            }
        }
    }

    @ViewBuilder
    private func editField(_ label: String, text: Binding<String>, hint: String, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.medium))
            if multiline {
                TextEditor(text: text)
                    .font(.body)
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            } else {
                TextField(hint, text: text)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func loadLocalization(_ loc: ASCBetaLocalization) {
        formRevision = asc.projectRevision
        editDescription = loc.attributes.description ?? ""
        editFeedbackEmail = loc.attributes.feedbackEmail ?? ""
        editMarketingUrl = loc.attributes.marketingUrl ?? ""
        editPrivacyUrl = loc.attributes.privacyPolicyUrl ?? ""
        populatedValues = editValues
        saveSuccess = false
        saveError = nil
    }

    private func save(locId: String) {
        guard !locId.isEmpty, locId == selectedLocId, formRevision == asc.projectRevision,
              asc.betaLocalizations.contains(where: { $0.id == locId }), let service = asc.service else { return }
        let revision = asc.projectRevision
        let values = editValues
        isSaving = true
        saveError = nil
        saveSuccess = false
        Task {
            guard revision == asc.projectRevision else { return }
            do {
                try await service.patchBetaLocalization(
                    id: locId,
                    locale: "",
                    description: values[0].isEmpty ? nil : values[0],
                    feedbackEmail: values[1].isEmpty ? nil : values[1],
                    marketingUrl: values[2].isEmpty ? nil : values[2],
                    privacyPolicyUrl: values[3].isEmpty ? nil : values[3]
                )
                guard revision == asc.projectRevision else { return }
                saveSuccess = true
                populatedValues = values
                // Refresh tab data
                await asc.refreshTabData(.betaInfo)
            } catch {
                guard revision == asc.projectRevision else { return }
                saveError = error.localizedDescription
            }
            guard revision == asc.projectRevision else { return }
            isSaving = false
            syncLocalization()
        }
    }
}
