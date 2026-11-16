// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI
import UniformTypeIdentifiers

struct MonetizationView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }

    private var selectedVersionBinding: Binding<String> {
        Binding(
            get: { asc.selectedVersion?.id ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                asc.prepareForVersionSelection(newValue)
                Task { await asc.refreshTabData(.monetization) }
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
            ASCTabContent(appState: appState, asc: asc, tab: .monetization, platform: appState.activeProject?.platform ?? .iOS, allowWithoutLocalProject: true) {
                monetizationContent
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            // This view stays mounted off-screen so creation progress survives
            // tab switches; only the visible Monetization tab should auto-load.
            guard appState.activeTab == .monetization else { return }
            await asc.ensureTabData(.monetization)
        }
    }

    @ViewBuilder
    private var monetizationContent: some View {
        let isLoading = asc.isTabLoading(.monetization)
        VStack(spacing: 0) {
            if asc.app != nil {
                ASCVersionPickerBar(
                    asc: asc,
                    selection: selectedVersionBinding,
                    appStoreURL: asc.app.flatMap { URL(string: "https://appstoreconnect.apple.com/apps/\($0.id)/distribution/pricing") },
                    refreshTab: .monetization,
                    refreshHelpText: L10n.tr("Preise und Kaufprodukte aktualisieren")
                )
                .blitzToolbar()
            }

            Divider()

        ScrollView {
            VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                if let err = asc.writeError {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if isLoading
                    && asc.appPricePoints.isEmpty
                    && asc.inAppPurchases.isEmpty
                    && asc.subscriptionGroups.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("Preise, In-App-Käufe und Abos werden geladen …"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                AppPricingSection(asc: asc)
                InAppPurchasesSection(asc: asc)
                SubscriptionsSection(asc: asc)
            }
            .blitzPagePadding()
        }
        }
    }
}

// MARK: - Shared Price Picker

private struct PricePicker: View {
    let pricePoints: [ASCPricePoint]
    @Binding var selectedPointId: String

    private var sortedPaidPoints: [ASCPricePoint] {
        pricePoints
            .filter { Double($0.attributes.customerPrice ?? "0") ?? 0 > 0 }
            .sorted { (Double($0.attributes.customerPrice ?? "0") ?? 0) < (Double($1.attributes.customerPrice ?? "0") ?? 0) }
    }

    var body: some View {
        Picker(L10n.tr("Preis"), selection: $selectedPointId) {
            Text(L10n.tr("Preis auswählen …")).tag("")
            ForEach(sortedPaidPoints) { pt in
                Text("$\(pt.attributes.customerPrice ?? "?")").tag(pt.id)
            }
        }
    }
}

// MARK: - Screenshot Picker

private struct ScreenshotPicker: View {
    let label: String
    @Binding var path: String
    @State private var showPicker = false

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if path.isEmpty {
                Button(L10n.tr("Datei auswählen …")) { showPicker = true }
                    .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                    Button(L10n.tr("Ändern")) { showPicker = true }
                        .controlSize(.mini)
                }
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.png, .jpeg]) { result in
            if case .success(let url) = result {
                path = url.path
            }
        }
    }
}

// MARK: - Create Progress Bar

private struct CreateProgressBar: View {
    let progress: Double
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
        }
    }
}

// MARK: - Section Card

private struct SectionCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content()
        }
        .font(BlitzLayout.bodyFont)
        .padding(BlitzLayout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Section 1: App Pricing

private struct AppPricingSection: View {
    var asc: ASCManager
    @State private var isFree = true
    @State private var selectedPricePointId = ""
    @State private var isSaving = false
    @State private var showScheduled = false
    @State private var scheduledDate = Date().addingTimeInterval(86400 * 7)
    @State private var scheduledPricePointId = ""

    var body: some View {
        let isLoading = asc.isTabLoading(.monetization)
        SectionCard {
            Label(L10n.tr("Preise und Verfügbarkeit"), systemImage: "dollarsign.circle")
                .font(BlitzLayout.sectionTitle)

            if isLoading && asc.appPricePoints.isEmpty && asc.currentAppPricePointId == nil && asc.scheduledAppPricePointId == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("Preisdaten werden geladen …"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("Kostenlose App")).font(.body.weight(.medium))
                        Text(L10n.tr("Die App wird im App Store kostenlos angeboten."))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isFree },
                        set: { newValue in
                            guard newValue != isFree else { return }
                            isFree = newValue
                            guard newValue else { return }
                            isSaving = true
                            selectedPricePointId = ""
                            Task {
                                await asc.setPriceFree()
                                isSaving = false
                            }
                        }
                    ))
                        .labelsHidden()
                        .accessibilityLabel(L10n.tr("Kostenlose App"))
                        .fixedSize()
                }

                if !isFree {
                    PricePicker(pricePoints: asc.appPricePoints, selectedPointId: $selectedPricePointId)

                    if !selectedPricePointId.isEmpty {
                        Button(L10n.tr("Preis speichern")) {
                            isSaving = true
                            Task {
                                await asc.setAppPrice(pricePointId: selectedPricePointId)
                                isSaving = false
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation { showScheduled.toggle() }
                        } label: {
                            HStack {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .rotationEffect(.degrees(showScheduled ? 90 : 0))
                                    .animation(.easeInOut(duration: 0.15), value: showScheduled)
                                Text(L10n.tr("Preisänderung planen"))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showScheduled {
                            VStack(alignment: .leading, spacing: 12) {
                                DatePicker(L10n.tr("Gültig ab"), selection: $scheduledDate, in: Date()..., displayedComponents: .date)
                                PricePicker(pricePoints: asc.appPricePoints, selectedPointId: $scheduledPricePointId)

                                if !scheduledPricePointId.isEmpty {
                                    Button(L10n.tr("Preisänderung speichern")) {
                                        isSaving = true
                                        let currentId = selectedPricePointId.isEmpty ? freePointId : selectedPricePointId
                                        let dateStr = formatDate(scheduledDate)
                                        Task {
                                            await asc.setScheduledAppPrice(
                                                currentPricePointId: currentId,
                                                futurePricePointId: scheduledPricePointId,
                                                effectiveDate: dateStr
                                            )
                                            isSaving = false
                                        }
                                    }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                }
            }

            if isSaving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("Wird gespeichert …")).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { syncFromASC() }
        .onChange(of: asc.currentAppPricePointId) { _, _ in syncFromASC() }
        .onChange(of: asc.scheduledAppPricePointId) { _, _ in syncFromASC() }
        .onChange(of: asc.scheduledAppPriceEffectiveDate) { _, _ in syncFromASC() }
        .onChange(of: asc.appPricePoints.count) { _, _ in syncFromASC() }
    }

    private var freePointId: String {
        asc.freeAppPricePointId ?? ""
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private func syncFromASC() {
        let resolvedCurrentId = asc.currentAppPricePointId
            ?? ((asc.monetizationStatus == "Free" && !freePointId.isEmpty) ? freePointId : nil)

        if let resolvedCurrentId, !resolvedCurrentId.isEmpty {
            let currentlyFree = resolvedCurrentId == freePointId || asc.isFreePricePoint(resolvedCurrentId)
            isFree = currentlyFree
            selectedPricePointId = currentlyFree ? "" : resolvedCurrentId
        } else {
            let currentlyFree = asc.monetizationStatus != "Configured"
            isFree = currentlyFree
            if currentlyFree {
                selectedPricePointId = ""
            }
        }

        if let scheduledPricePointId = asc.scheduledAppPricePointId {
            self.scheduledPricePointId = scheduledPricePointId
            showScheduled = true
        }
        if let effectiveDate = asc.scheduledAppPriceEffectiveDate,
           let parsedDate = parseDate(effectiveDate) {
            scheduledDate = parsedDate
        }
    }

    private func parseDate(_ value: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: value)
    }
}

// MARK: - Section 2: In-App Purchases

private struct InAppPurchasesSection: View {
    var asc: ASCManager
    @State private var showCreateForm = false
    @State private var expandedId: String?
    // Create form
    @State private var iapType = "CONSUMABLE"
    @State private var iapRefName = ""
    @State private var iapProductId = ""
    @State private var iapDisplayName = ""
    @State private var iapDescription = ""
    @State private var iapPricePointId = ""
    @State private var iapScreenshotPath = ""
    @State private var showValidation = false
    @State private var deleteTarget: ASCInAppPurchase?

    private let iapTypes = ["CONSUMABLE", "NON_CONSUMABLE", "NON_RENEWING_SUBSCRIPTION"]

    private var missingFields: [String] {
        var missing: [String] = []
        if iapRefName.isEmpty { missing.append(L10n.tr("Referenzname")) }
        if iapProductId.isEmpty { missing.append(L10n.tr("Produkt-ID")) }
        if iapDisplayName.isEmpty { missing.append(L10n.tr("Anzeigename")) }
        if iapDescription.isEmpty { missing.append(L10n.tr("Beschreibung")) }
        if iapScreenshotPath.isEmpty { missing.append(L10n.tr("Prüfbild")) }
        return missing
    }

    var body: some View {
        let isLoading = asc.isTabLoading(.monetization)
        SectionCard {
            HStack {
                Label(L10n.tr("In-App-Käufe"), systemImage: "cart")
                    .font(BlitzLayout.sectionTitle)
                Spacer()
                Button(showCreateForm ? L10n.tr("Abbrechen") : L10n.tr("Kauf hinzufügen …")) {
                    showCreateForm.toggle()
                    if !showCreateForm { resetForm() }
                }
                .controlSize(.small)
            }

            if asc.inAppPurchases.isEmpty && !showCreateForm {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("In-App-Käufe werden geladen …"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.tr("Noch keine In-App-Käufe eingerichtet."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ForEach(asc.inAppPurchases) { iap in
                    IAPDetailRow(
                        iap: iap, asc: asc,
                        isExpanded: expandedId == iap.id,
                        onToggle: { expandedId = expandedId == iap.id ? nil : iap.id },
                        onDelete: { deleteTarget = iap }
                    )
                }
            }

            if showCreateForm {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.tr("Neuer In-App-Kauf")).font(.subheadline.weight(.semibold))

                    BlitzSetupField(L10n.tr("Typ")) {
                        Picker(L10n.tr("Typ"), selection: $iapType) {
                            ForEach(iapTypes, id: \.self) { Text(formatType($0)).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .accessibilityLabel(L10n.tr("Typ"))
                    }

                    RequiredField(L10n.tr("Referenzname"), text: $iapRefName, showError: showValidation && iapRefName.isEmpty)
                    RequiredField(L10n.tr("Produkt-ID"), text: $iapProductId, showError: showValidation && iapProductId.isEmpty)
                    RequiredField(L10n.tr("Anzeigename"), text: $iapDisplayName, showError: showValidation && iapDisplayName.isEmpty)
                    RequiredField(L10n.tr("Beschreibung"), text: $iapDescription, showError: showValidation && iapDescription.isEmpty)
                    PricePicker(pricePoints: asc.appPricePoints, selectedPointId: $iapPricePointId)
                    ScreenshotPicker(label: L10n.tr("Prüfbild"), path: $iapScreenshotPath)
                    if showValidation && iapScreenshotPath.isEmpty {
                        Text(L10n.tr("Ein Prüfbild ist erforderlich."))
                            .font(.caption2).foregroundStyle(.red)
                    } else {
                        Text(L10n.tr("Mindestens 640 × 920 Pixel, PNG oder JPEG. Für die App-Prüfung erforderlich."))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }

                    if showValidation && !missingFields.isEmpty {
                        Text(L10n.tr("Erforderlich: \(missingFields.joined(separator: ", "))"))
                            .font(.caption).foregroundStyle(.red)
                    }

                    if asc.isCreating {
                        CreateProgressBar(progress: asc.createProgress, message: asc.createProgressMessage)
                    } else {
                        Button(L10n.tr("In-App-Kauf anlegen")) {
                            if !missingFields.isEmpty {
                                showValidation = true
                                return
                            }
                            let price = priceForPointId(iapPricePointId)
                            asc.createIAP(
                                name: iapRefName, productId: iapProductId, type: iapType,
                                displayName: iapDisplayName,
                                description: iapDescription,
                                price: price, screenshotPath: iapScreenshotPath
                            )
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
        }
        .onChange(of: asc.isCreating) { wasCreating, nowCreating in
            if wasCreating && !nowCreating && asc.writeError == nil {
                showCreateForm = false; resetForm()
            }
        }
        .alert(L10n.tr("In-App-Kauf löschen?"), isPresented: .init(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        )) {
            Button(L10n.tr("Löschen"), role: .destructive) {
                if let t = deleteTarget { Task { await asc.deleteIAP(id: t.id) } }
            }
            Button(L10n.tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(L10n.tr("„\(deleteTarget?.attributes.name ?? "")“ wird dauerhaft gelöscht."))
        }
        .onChange(of: asc.pendingCreateValues) { _, pending in
            guard let pending, pending["kind"] == "iap" else { return }
            showCreateForm = true
            if let v = pending["type"] { iapType = v }
            if let v = pending["name"] { iapRefName = v }
            if let v = pending["productId"] { iapProductId = v }
            if let v = pending["displayName"] { iapDisplayName = v }
            if let v = pending["description"] { iapDescription = v }
            asc.pendingCreateValues = nil
        }
    }

    private func resetForm() {
        iapType = "CONSUMABLE"; iapRefName = ""; iapProductId = ""
        iapDisplayName = ""; iapDescription = ""; iapPricePointId = ""
        iapScreenshotPath = ""; showValidation = false
    }

    private func priceForPointId(_ id: String) -> String {
        asc.appPricePoints.first(where: { $0.id == id })?.attributes.customerPrice ?? ""
    }
}

// MARK: - Required Field

private struct RequiredField: View {
    let title: String
    @Binding var text: String
    let showError: Bool

    init(_ title: String, text: Binding<String>, showError: Bool) {
        self.title = title
        self._text = text
        self.showError = showError
    }

    var body: some View {
        BlitzSetupField(title) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(showError ? .red : .clear, lineWidth: 1)
                )
            if showError {
                Text(L10n.tr("\(title) ist erforderlich."))
                    .font(.caption2).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - IAP Expandable Row

private struct IAPDetailRow: View {
    let iap: ASCInAppPurchase
    var asc: ASCManager
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var editName: String = ""
    @State private var editDisplayName: String = ""
    @State private var editDescription: String = ""
    @State private var editReviewNote: String = ""
    @State private var screenshotPath: String = ""
    @State private var isSaving = false
    @State private var isUploading = false
    @State private var didLoadFields = false
    @State private var showValidation = false

    private var canEditReview: Bool { ASCEditability.canEditProductReview(iap.attributes.state) }
    private var canEditLocalization: Bool { ASCEditability.canEditProductLocalization(iap.attributes.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            BlitzFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(iap.attributes.name ?? L10n.tr("Ohne Namen")).font(.body.weight(.medium))
                            BlitzFlowLayout(horizontalSpacing: 8, verticalSpacing: 4) {
                                Text(iap.attributes.productId ?? "").font(.caption).foregroundStyle(.secondary)
                                Text(formatType(iap.attributes.inAppPurchaseType))
                                    .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.blue.opacity(0.15)).clipShape(Capsule())
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                if iap.attributes.state == "READY_TO_SUBMIT" {
                    SubmitForReviewButton(
                        itemName: iap.attributes.name ?? L10n.tr("In-App-Kauf"),
                        asc: asc,
                        onSubmit: { await asc.submitIAPForReview(id: iap.id) }
                    )
                } else {
                    stateBadge(iap.attributes.state)
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.caption)
                }.buttonStyle(.borderless)
            }
            .padding(.vertical, 6)

            // Expanded edit fields
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    RequiredField(L10n.tr("Referenzname"), text: $editName, showError: showValidation && editName.isEmpty)
                    RequiredField(L10n.tr("Anzeigename"), text: $editDisplayName, showError: showValidation && editDisplayName.isEmpty)
                        .disabled(!canEditLocalization)
                    RequiredField(L10n.tr("Beschreibung"), text: $editDescription, showError: showValidation && editDescription.isEmpty)
                        .disabled(!canEditLocalization)
                    TextField(L10n.tr("Hinweise für die App-Prüfung"), text: $editReviewNote, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)
                        .disabled(!canEditReview)

                    if !canEditReview {
                        Label(L10n.tr("Prüfunterlagen sind für diesen Produktstatus gesperrt."), systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ScreenshotPicker(label: L10n.tr("Prüfbild"), path: $screenshotPath)
                        .disabled(!canEditReview)
                    if canEditReview && !screenshotPath.isEmpty {
                        HStack {
                            Button(L10n.tr("Prüfbild hochladen")) {
                                isUploading = true
                                Task {
                                    await asc.uploadIAPScreenshot(iapId: iap.id, path: screenshotPath)
                                    isUploading = false
                                }
                            }
                            .controlSize(.small)
                            if isUploading { ProgressView().controlSize(.small) }
                        }
                    }

                    if showValidation && (editDisplayName.isEmpty || editDescription.isEmpty) {
                        Text(L10n.tr("Anzeigename und Beschreibung sind erforderlich."))
                            .font(.caption).foregroundStyle(.red)
                    }

                    HStack {
                        Button(L10n.tr("Speichern")) {
                            if canEditLocalization && (editDisplayName.isEmpty || editDescription.isEmpty) {
                                showValidation = true
                                return
                            }
                            isSaving = true
                            Task {
                                await asc.updateIAP(
                                    id: iap.id,
                                    name: editName.isEmpty ? nil : editName,
                                    reviewNote: canEditReview ? editReviewNote : nil,
                                    displayName: canEditLocalization ? editDisplayName : nil,
                                    description: canEditLocalization ? editDescription : nil
                                )
                                isSaving = false
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(isSaving)
                        if isSaving { ProgressView().controlSize(.small) }
                    }
                }
                .padding(.leading, 20)
                .padding(.bottom, 8)
                .onAppear { loadFields() }
            }
        }
    }

    private func loadFields() {
        guard !didLoadFields else { return }
        didLoadFields = true
        editName = iap.attributes.name ?? ""
        editReviewNote = iap.attributes.reviewNote ?? ""
        editDisplayName = ""
        editDescription = ""
    }
}

// MARK: - Section 3: Subscriptions

private struct SubscriptionsSection: View {
    var asc: ASCManager
    @State private var showCreateForm = false
    @State private var expandedId: String?
    // Create form
    @State private var subGroupName = ""
    @State private var newGroupName = ""
    @State private var subRefName = ""
    @State private var subProductId = ""
    @State private var subDisplayName = ""
    @State private var subDescription = ""
    @State private var subDuration = "ONE_MONTH"
    @State private var subPricePointId = ""
    @State private var subScreenshotPath = ""
    @State private var showValidation = false
    @State private var deleteTarget: ASCSubscription?
    @State private var deleteGroupTarget: ASCSubscriptionGroup?

    private let durations = ["ONE_WEEK", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS", "SIX_MONTHS", "ONE_YEAR"]

    private var effectiveGroupName: String {
        subGroupName.isEmpty ? newGroupName : subGroupName
    }

    private var missingFields: [String] {
        var missing: [String] = []
        if effectiveGroupName.isEmpty { missing.append(L10n.tr("Gruppenname")) }
        if subRefName.isEmpty { missing.append(L10n.tr("Referenzname")) }
        if subProductId.isEmpty { missing.append(L10n.tr("Produkt-ID")) }
        if subDisplayName.isEmpty { missing.append(L10n.tr("Anzeigename")) }
        if subDescription.isEmpty { missing.append(L10n.tr("Beschreibung")) }
        if subScreenshotPath.isEmpty { missing.append(L10n.tr("Prüfbild")) }
        return missing
    }

    var body: some View {
        let isLoading = asc.isTabLoading(.monetization)
        SectionCard {
            HStack {
                Label(L10n.tr("Abos"), systemImage: "arrow.triangle.2.circlepath")
                    .font(BlitzLayout.sectionTitle)
                Spacer()
                Button(showCreateForm ? L10n.tr("Abbrechen") : L10n.tr("Abo hinzufügen …")) {
                    showCreateForm.toggle()
                    if !showCreateForm { resetForm() }
                }
                .controlSize(.small)
            }

            if asc.subscriptionGroups.isEmpty && !showCreateForm {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("Abos werden geladen …"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.tr("Noch keine Abos eingerichtet."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ForEach(asc.subscriptionGroups) { group in
                    SubscriptionGroupRow(
                        group: group, asc: asc,
                        expandedId: $expandedId,
                        deleteTarget: $deleteTarget,
                        onDeleteGroup: { deleteGroupTarget = group }
                    )
                }
            }

            if showCreateForm {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.tr("Neues Abo")).font(.subheadline.weight(.semibold))

                    if asc.subscriptionGroups.isEmpty {
                        RequiredField(L10n.tr("Name der Abo-Gruppe"), text: $newGroupName,
                                      showError: showValidation && effectiveGroupName.isEmpty)
                    } else {
                        Picker(L10n.tr("Gruppe"), selection: $subGroupName) {
                            Text(L10n.tr("Neue Gruppe …")).tag("")
                            ForEach(asc.subscriptionGroups) { g in
                                Text(g.attributes.referenceName ?? g.id).tag(g.attributes.referenceName ?? g.id)
                            }
                        }
                        if subGroupName.isEmpty {
                            RequiredField(L10n.tr("Name der neuen Gruppe"), text: $newGroupName,
                                          showError: showValidation && effectiveGroupName.isEmpty)
                        }
                    }

                    RequiredField(L10n.tr("Referenzname"), text: $subRefName, showError: showValidation && subRefName.isEmpty)
                    RequiredField(L10n.tr("Produkt-ID"), text: $subProductId, showError: showValidation && subProductId.isEmpty)
                    RequiredField(L10n.tr("Anzeigename"), text: $subDisplayName, showError: showValidation && subDisplayName.isEmpty)
                    RequiredField(L10n.tr("Beschreibung"), text: $subDescription, showError: showValidation && subDescription.isEmpty)

                    Picker(L10n.tr("Laufzeit"), selection: $subDuration) {
                        ForEach(durations, id: \.self) { Text(formatDuration($0)).tag($0) }
                    }

                    PricePicker(pricePoints: asc.appPricePoints, selectedPointId: $subPricePointId)
                    ScreenshotPicker(label: L10n.tr("Prüfbild"), path: $subScreenshotPath)
                    if showValidation && subScreenshotPath.isEmpty {
                        Text(L10n.tr("Ein Prüfbild ist erforderlich."))
                            .font(.caption2).foregroundStyle(.red)
                    } else {
                        Text(L10n.tr("Mindestens 640 × 920 Pixel, PNG oder JPEG. Für die App-Prüfung erforderlich."))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }

                    if showValidation && !missingFields.isEmpty {
                        Text(L10n.tr("Erforderlich: \(missingFields.joined(separator: ", "))"))
                            .font(.caption).foregroundStyle(.red)
                    }

                    if asc.isCreating {
                        CreateProgressBar(progress: asc.createProgress, message: asc.createProgressMessage)
                    } else {
                        Button(L10n.tr("Abo anlegen")) {
                            if !missingFields.isEmpty {
                                showValidation = true
                                return
                            }
                            let price = priceForPointId(subPricePointId)
                            asc.createSubscription(
                                groupName: effectiveGroupName, name: subRefName,
                                productId: subProductId, displayName: subDisplayName,
                                description: subDescription,
                                duration: subDuration, price: price, screenshotPath: subScreenshotPath
                            )
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
        }
        .onChange(of: asc.isCreating) { wasCreating, nowCreating in
            if wasCreating && !nowCreating && asc.writeError == nil {
                showCreateForm = false; resetForm()
            }
        }
        .alert(L10n.tr("Abo löschen?"), isPresented: .init(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        )) {
            Button(L10n.tr("Löschen"), role: .destructive) {
                if let t = deleteTarget { Task { await asc.deleteSubscription(id: t.id) } }
            }
            Button(L10n.tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(L10n.tr("„\(deleteTarget?.attributes.name ?? "")“ wird dauerhaft gelöscht."))
        }
        .alert(L10n.tr("Abo-Gruppe löschen?"), isPresented: .init(
            get: { deleteGroupTarget != nil }, set: { if !$0 { deleteGroupTarget = nil } }
        )) {
            Button(L10n.tr("Löschen"), role: .destructive) {
                if let g = deleteGroupTarget { Task { await asc.deleteSubscriptionGroup(id: g.id) } }
            }
            Button(L10n.tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(L10n.tr("Die Gruppe „\(deleteGroupTarget?.attributes.referenceName ?? "")“ wird dauerhaft gelöscht."))
        }
        .onChange(of: asc.pendingCreateValues) { _, pending in
            guard let pending, pending["kind"] == "subscription" else { return }
            showCreateForm = true
            if let v = pending["groupName"] { subGroupName = v; newGroupName = v }
            if let v = pending["name"] { subRefName = v }
            if let v = pending["productId"] { subProductId = v }
            if let v = pending["displayName"] { subDisplayName = v }
            if let v = pending["description"] { subDescription = v }
            if let v = pending["duration"] { subDuration = v }
            asc.pendingCreateValues = nil
        }
    }

    private func resetForm() {
        subGroupName = ""; newGroupName = ""; subRefName = ""; subProductId = ""
        subDisplayName = ""; subDescription = ""; subDuration = "ONE_MONTH"
        subPricePointId = ""; subScreenshotPath = ""; showValidation = false
    }

    private func priceForPointId(_ id: String) -> String {
        asc.appPricePoints.first(where: { $0.id == id })?.attributes.customerPrice ?? ""
    }
}

// MARK: - Subscription Group Row

private struct SubscriptionGroupRow: View {
    let group: ASCSubscriptionGroup
    var asc: ASCManager
    @Binding var expandedId: String?
    @Binding var deleteTarget: ASCSubscription?
    let onDeleteGroup: () -> Void
    @State private var editGroupName: String = ""
    @State private var isSavingGroup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.attributes.referenceName ?? L10n.tr("Gruppe"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if asc.subscriptionsPerGroup[group.id]?.isEmpty == true {
                    Button(role: .destructive, action: onDeleteGroup) {
                        Image(systemName: "trash").font(.caption)
                    }.buttonStyle(.borderless)
                }
            }

            // Group localization edit
            HStack(spacing: 8) {
                TextField(L10n.tr("Anzeigename der Gruppe"), text: $editGroupName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button(L10n.tr("Speichern")) {
                    guard !editGroupName.isEmpty else { return }
                    isSavingGroup = true
                    Task {
                        await asc.updateSubscriptionGroupLocalization(groupId: group.id, name: editGroupName)
                        isSavingGroup = false
                    }
                }
                .controlSize(.mini)
                .disabled(editGroupName.isEmpty || isSavingGroup)
                if isSavingGroup { ProgressView().controlSize(.mini) }
            }

            let subs = asc.subscriptionsPerGroup[group.id] ?? []
            if subs.isEmpty {
                if asc.isTabLoading(.monetization) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(L10n.tr("Abos dieser Gruppe werden geladen …"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(L10n.tr("Keine Abos in dieser Gruppe."))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            ForEach(subs) { sub in
                SubscriptionDetailRow(
                    sub: sub, asc: asc,
                    isExpanded: expandedId == sub.id,
                    onToggle: { expandedId = expandedId == sub.id ? nil : sub.id },
                    onDelete: { deleteTarget = sub }
                )
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            if editGroupName.isEmpty {
                editGroupName = group.attributes.referenceName ?? ""
            }
        }
    }
}

// MARK: - Subscription Expandable Row

private struct SubscriptionDetailRow: View {
    let sub: ASCSubscription
    var asc: ASCManager
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var editName: String = ""
    @State private var editDisplayName: String = ""
    @State private var editDescription: String = ""
    @State private var editReviewNote: String = ""
    @State private var screenshotPath: String = ""
    @State private var isSaving = false
    @State private var isUploading = false
    @State private var didLoadFields = false
    @State private var showValidation = false

    private var canEditReview: Bool { ASCEditability.canEditProductReview(sub.attributes.state) }
    private var canEditLocalization: Bool { ASCEditability.canEditProductLocalization(sub.attributes.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BlitzFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.attributes.name ?? L10n.tr("Ohne Namen")).font(.body.weight(.medium))
                            BlitzFlowLayout(horizontalSpacing: 8, verticalSpacing: 4) {
                                Text(sub.attributes.productId ?? "").font(.caption).foregroundStyle(.secondary)
                                Text(formatDuration(sub.attributes.subscriptionPeriod))
                                    .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.purple.opacity(0.15)).clipShape(Capsule())
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                if sub.attributes.state == "READY_TO_SUBMIT" {
                    SubmitForReviewButton(
                        itemName: sub.attributes.name ?? L10n.tr("Abo"),
                        asc: asc,
                        onSubmit: { await asc.submitSubscriptionForReview(id: sub.id) }
                    )
                } else {
                    stateBadge(sub.attributes.state)
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.caption)
                }.buttonStyle(.borderless)
            }
            .padding(.vertical, 6)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    RequiredField(L10n.tr("Referenzname"), text: $editName, showError: showValidation && editName.isEmpty)
                    RequiredField(L10n.tr("Anzeigename"), text: $editDisplayName, showError: showValidation && editDisplayName.isEmpty)
                        .disabled(!canEditLocalization)
                    RequiredField(L10n.tr("Beschreibung"), text: $editDescription, showError: showValidation && editDescription.isEmpty)
                        .disabled(!canEditLocalization)
                    TextField(L10n.tr("Hinweise für die App-Prüfung"), text: $editReviewNote, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)
                        .disabled(!canEditReview)

                    if !canEditReview {
                        Label(L10n.tr("Prüfunterlagen sind für diesen Produktstatus gesperrt."), systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ScreenshotPicker(label: L10n.tr("Prüfbild"), path: $screenshotPath)
                        .disabled(!canEditReview)
                    if canEditReview && !screenshotPath.isEmpty {
                        HStack {
                            Button(L10n.tr("Prüfbild hochladen")) {
                                isUploading = true
                                Task {
                                    await asc.uploadSubscriptionScreenshot(subscriptionId: sub.id, path: screenshotPath)
                                    isUploading = false
                                }
                            }
                            .controlSize(.small)
                            if isUploading { ProgressView().controlSize(.small) }
                        }
                    }

                    if showValidation && (editDisplayName.isEmpty || editDescription.isEmpty) {
                        Text(L10n.tr("Anzeigename und Beschreibung sind erforderlich."))
                            .font(.caption).foregroundStyle(.red)
                    }

                    HStack {
                        Button(L10n.tr("Speichern")) {
                            if canEditLocalization && (editDisplayName.isEmpty || editDescription.isEmpty) {
                                showValidation = true
                                return
                            }
                            isSaving = true
                            Task {
                                await asc.updateSubscription(
                                    id: sub.id,
                                    name: editName.isEmpty ? nil : editName,
                                    reviewNote: canEditReview ? editReviewNote : nil,
                                    displayName: canEditLocalization ? editDisplayName : nil,
                                    description: canEditLocalization ? editDescription : nil
                                )
                                isSaving = false
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(isSaving)
                        if isSaving { ProgressView().controlSize(.small) }
                    }
                }
                .padding(.leading, 20)
                .padding(.bottom, 8)
                .onAppear { loadFields() }
            }
        }
    }

    private func loadFields() {
        guard !didLoadFields else { return }
        didLoadFields = true
        editName = sub.attributes.name ?? ""
        editReviewNote = sub.attributes.reviewNote ?? ""
        editDisplayName = ""
        editDescription = ""
    }
}

// MARK: - Submit Button

private struct SubmitForReviewButton: View {
    let itemName: String
    let asc: ASCManager
    let onSubmit: () async -> Bool

    @State private var showConfirm = false
    @State private var isSubmitting = false
    @State private var showFirstTimeAlert = false

    private var ascVersionURL: URL? {
        guard let appId = asc.app?.id else { return nil }
        return URL(string: "https://appstoreconnect.apple.com/apps/\(appId)/appstore")
    }

    var body: some View {
        Button(L10n.tr("Produkt zur Prüfung einreichen")) {
            showConfirm = true
        }
        .controlSize(.mini)
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .disabled(isSubmitting)
        .alert(L10n.tr("Dieses Produkt zur Prüfung einreichen?"), isPresented: $showConfirm) {
            Button(L10n.tr("Produkt einreichen")) {
                isSubmitting = true
                Task {
                    let success = await onSubmit()
                    isSubmitting = false
                    if !success, let err = asc.writeError, err.hasPrefix("FIRST_SUBMISSION:") {
                        asc.writeError = nil
                        showFirstTimeAlert = true
                    }
                }
            }
            Button(L10n.tr("Abbrechen"), role: .cancel) {}
        } message: {
            Text(L10n.tr("„\(itemName)“ einzeln zur App-Prüfung einreichen? Eine App-Version und weitere Produkte sind darin nicht enthalten."))
        }
        .alert(L10n.tr("Erstmalige Einreichung"), isPresented: $showFirstTimeAlert) {
            if let url = ascVersionURL {
                Button(L10n.tr("App Store Connect öffnen")) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(L10n.tr("Reiche diesen ersten In-App-Kauf oder dieses Abo gemeinsam mit einer App-Version über die Blitz-Neo-CLI oder MCP ein. Wähle die Produkte und gegebenenfalls die zugehörige Abo-Gruppe ausdrücklich aus. Es wird nichts automatisch hinzugefügt.\n\nDie manuelle Einreichungsvorschau umfasst nur die App. Eine gemeinsame Einreichung ist auch in App Store Connect möglich."))
        }
        .overlay {
            if isSubmitting {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

// MARK: - Helpers

private func formatType(_ type: String?) -> String {
    switch type {
    case "CONSUMABLE": return L10n.tr("Verbrauchbar")
    case "NON_CONSUMABLE": return L10n.tr("Nicht verbrauchbar")
    case "NON_RENEWING_SUBSCRIPTION": return L10n.tr("Abo ohne Verlängerung")
    default: return type ?? ""
    }
}

private func formatDuration(_ d: String?) -> String {
    switch d {
    case "ONE_WEEK": return L10n.tr("1 Woche")
    case "ONE_MONTH": return L10n.tr("1 Monat")
    case "TWO_MONTHS": return L10n.tr("2 Monate")
    case "THREE_MONTHS": return L10n.tr("3 Monate")
    case "SIX_MONTHS": return L10n.tr("6 Monate")
    case "ONE_YEAR": return L10n.tr("1 Jahr")
    default: return d ?? ""
    }
}

@ViewBuilder
private func stateBadge(_ state: String?) -> some View {
    let color: Color = switch state {
    case "READY_TO_SUBMIT": .green
    case "MISSING_METADATA": .orange
    case "WAITING_FOR_REVIEW", "IN_REVIEW": .blue
    case "APPROVED": .green
    default: .secondary
    }
    let label: String = switch state {
    case "READY_TO_SUBMIT": L10n.tr("Bereit zur Einreichung")
    case "MISSING_METADATA": L10n.tr("Angaben fehlen")
    case "WAITING_FOR_REVIEW": L10n.tr("Wartet auf Prüfung")
    case "IN_REVIEW": L10n.tr("In Prüfung")
    case "APPROVED": L10n.tr("Genehmigt")
    case "REJECTED": L10n.tr("Abgelehnt")
    case "DEVELOPER_ACTION_NEEDED": L10n.tr("Aktion erforderlich")
    case "DEVELOPER_REMOVED_FROM_SALE": L10n.tr("Vom Verkauf zurückgezogen")
    case "REMOVED_FROM_SALE": L10n.tr("Nicht im Verkauf")
    default: state ?? ""
    }
    Text(label)
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
}
