// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

struct SubmitPreviewSheet: View {
    var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var asc: ASCManager { appState.ascManager }

    @State private var isCheckingReadiness = true
    @State private var selectedBuildId: String = ""
    @State private var appIcon: NSImage?

    @State private var releaseTarget: ASCReleaseOperationTarget?
    @State private var expectedReleaseMode: String?
    @State private var confirmedIssuesResolved = false
    @State private var previewedSubmissionID: String?

    private var targetMatches: Bool { releaseTarget?.matches(asc) == true }
    private var validBuilds: [ASCBuild] {
        guard targetMatches, let target = releaseTarget, let platform = target.platform,
              let version = targetVersion else { return [] }
        return asc.builds.filter { $0.matchesRelease(appId: target.appId, versionString: version.attributes.versionString, platform: platform) }
    }
    private var targetVersion: ASCAppStoreVersion? {
        guard targetMatches else { return nil }
        return asc.selectedVersion
    }
    private var versionState: String { targetVersion?.attributes.effectiveState ?? "" }
    private var reviewProgress: ASCReviewProgress { ASCReviewProgress(asc: asc, version: targetVersion) }
    private var isSubmittable: Bool { targetMatches && reviewProgress.canPreviewSubmission }
    private var preservesExistingBuild: Bool { reviewProgress.isRecovery || versionState == "READY_FOR_REVIEW" }
    private var selectedBuild: ASCBuild? { validBuilds.first { $0.id == selectedBuildId } }

    var body: some View {
        VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
            BlitzSetupHeader(L10n.tr("Einreichung prüfen"), subtitle: L10n.tr("Prüfe die ausgewählte Version, den Build und die Veröffentlichungsart vor dem Absenden an Apple."))

            Divider()

            BlitzSetupScrollArea(maxHeight: 360) {
                VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                    HStack(alignment: .top, spacing: BlitzLayout.sectionSpacing) {
                        if let icon = appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.blue.gradient)
                                .frame(width: 64, height: 64)
                                .overlay(
                                    Image(systemName: "app.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.white)
                                )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(asc.app?.name ?? "App")
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            if let version = targetVersion {
                                Text("Version \(version.attributes.versionString)")
                                    .foregroundStyle(.secondary)
                            }
                            Text(asc.app?.bundleId ?? "")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if asc.canCreateUpdate, let version = targetVersion {
                                // This branch shows draft guidance below, not the status card.
                                ASCStatusBadge(presentation: ASCReleaseStatusPresentation.version(
                                    version, distributionReadyVersionID: asc.distributionReadyVersion?.id
                                ))
                            }
                            if !isSubmittable, let version = targetVersion,
                               ASCReleaseStatus.isLive(version.attributes.effectiveState),
                               version.id == asc.distributionReadyVersion?.id {
                                ASCStatusBadge(presentation: ASCReleaseStatusPresentation.store(
                                    distributionReadyVersionID: asc.distributionReadyVersion?.id,
                                    liveVersionID: asc.storeLiveVersion?.id,
                                    availability: asc.confirmedStoreAvailability,
                                    isLoading: asc.isStoreAvailabilityLoading,
                                    failed: asc.storeAvailabilityFailed
                                ))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if targetMatches, !isCheckingReadiness {
                        ASCReviewProgressView(progress: reviewProgress)
                    }
                    if isSubmittable {
                        if preservesExistingBuild {
                            Label(L10n.tr("Vorhandener Build: \(selectedBuild?.attributes.version ?? "—")"), systemImage: "shippingbox")
                                .font(.callout)
                        } else { buildSelector }
                        if reviewProgress.requiresResolution {
                            Toggle(isOn: $confirmedIssuesResolved) {
                                Text(L10n.tr("Ich habe Apples Hinweise geprüft und die abgelehnten Elemente korrigiert. Blitz darf diese Probleme als geklärt markieren und dieselbe Einreichung erneut absenden."))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }

                    if releaseTarget != nil && !targetMatches {
                        Text(L10n.tr("Die ausgewählte App oder Version hat sich geändert. Bitte diese Vorschau schließen und erneut öffnen."))
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if !isCheckingReadiness, previewedSubmissionID != reviewProgress.submissionID {
                        Text(L10n.tr("Der Prüfstatus oder die offenen Probleme haben sich geändert. Bitte die Vorschau erneut öffnen und die bestehende Einreichung bestätigen."))
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if isCheckingReadiness {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L10n.tr("Aktuellen Store-Stand prüfen …"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }

                    if asc.canCreateUpdate {
                        createUpdateRequiredContent
                    } else if isSubmittable {
                        if let mode = expectedReleaseMode.flatMap(ReleaseWorkflowMode.init(rawValue:)) {
                            Label(mode == .manual ? L10n.tr("Veröffentlichung: manuell nach Apples Freigabe") : L10n.tr("Veröffentlichung: automatisch nach Apples Freigabe"),
                                  systemImage: "calendar.badge.checkmark")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if !isCheckingReadiness {
                            Text(L10n.tr("Die Veröffentlichungsart ist unbekannt oder geplant. Bitte in App Store Connect „Manuell“ oder „Nach Freigabe automatisch“ wählen und diese Vorschau neu öffnen."))
                                .font(.callout).foregroundStyle(.orange)
                        }
                        submittableContent
                    } else {
                        nonSubmittableContent
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: BlitzLayout.fieldSpacing) {
                Button(isSubmittable ? L10n.tr("Abbrechen") : L10n.tr("Schließen")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if asc.canCreateUpdate {
                    Button(L10n.tr("Versionsentwurf anlegen")) {
                        asc.showVersionDraftSheet = true
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else if isSubmittable {
                    Button(reviewProgress.isRecovery ? L10n.tr("Erneut zur Prüfung einreichen") : L10n.tr("Zur Prüfung einreichen")) {
                        Task {
                            let buildId = preservesExistingBuild || selectedBuildId.isEmpty ? nil : selectedBuildId
                            guard let releaseTarget, releaseTarget.matches(asc) else { return }
                            if await asc.submitForReview(attachBuildId: buildId, expectedTarget: releaseTarget,
                                                        expectedReleaseMode: expectedReleaseMode,
                                                        expectedReviewSubmissionID: reviewProgress.isRecovery ? previewedSubmissionID : nil,
                                                        resolveRejectedItems: reviewProgress.requiresResolution && confirmedIssuesResolved) {
                                dismiss()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCheckingReadiness || asc.isSubmitting || !asc.submissionReadiness.isComplete(selectingBuild: selectedBuild) || selectedBuild == nil
                              || expectedReleaseMode.flatMap(ReleaseWorkflowMode.init(rawValue:)) == nil
                              || (reviewProgress.isRecovery && reviewProgress.submissionID == nil)
                              || (reviewProgress.requiresResolution && !confirmedIssuesResolved)
                              || previewedSubmissionID != reviewProgress.submissionID)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .font(.callout)
        .padding(24)
        .frame(width: 560)
        .task {
            defer { isCheckingReadiness = false }
            releaseTarget = asc.releaseOperationTarget()
            guard let initialTarget = releaseTarget else { isCheckingReadiness = false; return }
            // Read-only preview: opening it never attaches a build or saves fields.
            await asc.syncOverviewSubmissionReadiness(forceRefresh: true)
            guard !Task.isCancelled, initialTarget.matches(asc) else { return }
            releaseTarget = asc.releaseOperationTarget()
            guard let releaseTarget else { return }
            expectedReleaseMode = asc.selectedVersion?.attributes.releaseType
            previewedSubmissionID = reviewProgress.submissionID
            // The overview fetch also reloads the fully paginated build inventory.
            if let attached = asc.selectedVersionBuild, validBuilds.contains(where: { $0.id == attached.id }) {
                selectedBuildId = attached.id
            }
            appIcon = await loadAppIcon()
            guard !Task.isCancelled, releaseTarget.matches(asc) else { return }
            isCheckingReadiness = false
        }
    }

    private var createUpdateRequiredContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("Ein neuer Versionsentwurf ist erforderlich."))
                        .font(.callout.weight(.medium))
                    Text(L10n.tr("Lege zuerst einen Versionsentwurf an. Anschließend kannst du einen Build zuordnen und das Update einreichen."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(BlitzLayout.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Build Selector

    @ViewBuilder
    private var buildSelector: some View {
        if validBuilds.isEmpty && isCheckingReadiness {
            Text(L10n.tr("Builds werden geladen …"))
                .font(.callout).foregroundStyle(.secondary)
        } else if validBuilds.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(L10n.tr("Keine passenden Builds verfügbar"))
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            .padding(.top, 4)
        } else {
            BlitzSetupField("Build") {
                Picker("Build", selection: $selectedBuildId) {
                    Text(L10n.tr("Bitte auswählen …")).tag("")
                    ForEach(validBuilds) { build in
                        Text(build.attributes.version).tag(build.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Build")
            }
        }
    }

    // MARK: - Submittable Content

    @ViewBuilder
    private var submittableContent: some View {
        let readiness = SubmissionReadiness(fields: asc.submissionReadiness.fields.filter {
            selectedBuild == nil || $0.label != "Build"
        })
        if readiness.fields.contains(where: { $0.required && $0.loadFailed }) {
            Label(L10n.tr("Einige Pflichtangaben konnten nicht geprüft werden. Aktualisiere die Übersicht vor der Einreichung."),
                  systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
        }
        if !readiness.missingRequired.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("Fehlende Pflichtangaben"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                ForEach(readiness.missingRequired) { field in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(BlitzDisplayText.fieldLabel(field.label))
                            .font(.callout)
                    }
                }
            }
            .padding(BlitzLayout.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if asc.isSubmitting {
            HStack(spacing: 12) {
                ProgressView()
                Text(L10n.tr("Wird zur Prüfung eingereicht …"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }

        if let error = asc.submissionError {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .padding(8)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Non-Submittable Content

    private var nonSubmittableContent: some View {
        let presentation = ASCReleaseStatusPresentation.version(
            targetVersion, distributionReadyVersionID: asc.distributionReadyVersion?.id
        )
        let color = presentation.tone.color
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: presentation.symbol)
                    .font(.title3)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Status: \(presentation.label)")
                        .font(.callout.weight(.medium))
                    Text(L10n.tr("In diesem Zustand lässt sich der Build nicht ändern und die Version nicht erneut einreichen."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(BlitzLayout.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Show submission details when rejected
            if versionState == "REJECTED" {
                if !asc.latestSubmissionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(asc.latestSubmissionItems) { item in
                            HStack(spacing: 6) {
                                Image(systemName: item.attributes.state == "REJECTED" ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(item.attributes.state == "REJECTED" ? .red : .green)
                                    .font(.caption)
                                Text(BlitzDisplayText.status(item.attributes.state ?? ""))
                                    .font(.callout)
                            }
                        }
                    }
                    .padding(BlitzLayout.cardInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - App Icon Loading

    private func loadAppIcon() async -> NSImage? {
        guard let project = appState.activeProject else { return nil }
        return await ProjectAppIconLoader.loadImage(for: project.id, projectPath: project.path)
    }
}
