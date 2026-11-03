import SwiftUI

struct SubmitPreviewSheet: View {
    var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var asc: ASCManager { appState.ascManager }

    @State private var isCheckingReadiness = true
    @State private var selectedBuildId: String = ""
    @State private var appIcon: NSImage?

    @State private var releaseTarget: ASCReleaseOperationTarget?

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
    private var versionState: String { targetVersion?.attributes.appStoreState ?? "" }
    private var isSubmittable: Bool { targetMatches && ASCReleaseStatus.isEditable(versionState) }
    private var selectedBuild: ASCBuild? { validBuilds.first { $0.id == selectedBuildId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(asc.canCreateUpdate ? "Versionsentwurf anlegen" : (isSubmittable ? "Submit for Review" : "Submission Status"))
                .font(.title2.weight(.semibold))

            // App header: icon + info
            HStack(alignment: .top, spacing: 20) {
                // App icon
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                } else {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(.blue.gradient)
                        .frame(width: 100, height: 100)
                        .overlay(
                            Image(systemName: "app.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.white)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(asc.app?.name ?? "App")
                        .font(.title3.weight(.semibold))
                    if let version = targetVersion {
                        Text("Version \(version.attributes.versionString)")
                            .foregroundStyle(.secondary)
                    }
                    Text(asc.app?.bundleId ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    if isSubmittable {
                        buildSelector
                    } else {
                        versionStatusBadge
                    }
                }
            }

            Divider()

            if releaseTarget != nil && !targetMatches {
                Text("Die ausgewählte App oder Version hat sich geändert. Bitte diese Vorschau schließen und erneut öffnen.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if isCheckingReadiness {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking current App Store data…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if asc.canCreateUpdate {
                createUpdateRequiredContent
            } else if isSubmittable {
                submittableContent
            } else {
                nonSubmittableContent
            }

            // Footer buttons
            HStack {
                Button(isSubmittable ? "Cancel" : "Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if asc.canCreateUpdate {
                    Button("Versionsentwurf anlegen") {
                        asc.showVersionDraftSheet = true
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else if isSubmittable {
                    Button("Submit for Review") {
                        Task {
                            let buildId = selectedBuildId.isEmpty ? nil : selectedBuildId
                            guard let releaseTarget, releaseTarget.matches(asc) else { return }
                            if await asc.submitForReview(attachBuildId: buildId, expectedTarget: releaseTarget) {
                                dismiss()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCheckingReadiness || asc.isSubmitting || !asc.submissionReadiness.isComplete(selectingBuild: selectedBuild) || selectedBuild == nil)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .task {
            defer { isCheckingReadiness = false }
            releaseTarget = asc.releaseOperationTarget()
            guard let initialTarget = releaseTarget else { isCheckingReadiness = false; return }
            // Read-only preview: opening it never attaches a build or saves fields.
            await asc.syncOverviewSubmissionReadiness(forceRefresh: true)
            guard !Task.isCancelled, initialTarget.matches(asc) else { return }
            releaseTarget = asc.releaseOperationTarget()
            guard let releaseTarget else { return }
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
                    Text("This app is already live.")
                        .font(.callout.weight(.medium))
                    Text("Create a new App Store version before attaching a build and submitting an update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Build Selector

    @ViewBuilder
    private var buildSelector: some View {
        if validBuilds.isEmpty && isCheckingReadiness {
            Text("Loading builds…")
                .font(.callout).foregroundStyle(.secondary)
        } else if validBuilds.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text("No valid builds available")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            .padding(.top, 4)
        } else {
            Picker(selection: $selectedBuildId) {
                Text("Select a build\u{2026}").tag("")
                ForEach(validBuilds) { build in
                    Text("Build \(build.attributes.version)")
                        .tag(build.id)
                }
            } label: {
                Text("Build")
                    .font(.callout.weight(.medium))
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
            .padding(.top, 4)
        }
    }

    // MARK: - Version Status Badge (non-submittable)

    private var versionStatusBadge: some View {
        let (label, color) = stateDisplay(versionState)
        return HStack(spacing: 6) {
            Image(systemName: stateIcon(versionState))
                .foregroundStyle(color)
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.top, 4)
    }

    // MARK: - Submittable Content

    @ViewBuilder
    private var submittableContent: some View {
        let readiness = SubmissionReadiness(fields: asc.submissionReadiness.fields.filter {
            selectedBuild == nil || $0.label != "Build"
        })
        if readiness.fields.contains(where: { $0.required && $0.loadFailed }) {
            Label("Some required data could not be checked. Refresh the overview before submitting.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
        }
        if !readiness.missingRequired.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Missing Required Fields")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                ForEach(readiness.missingRequired) { field in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(field.label)
                            .font(.callout)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if asc.isSubmitting {
            HStack(spacing: 12) {
                ProgressView()
                Text("Submitting for review\u{2026}")
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
        let (label, color) = stateDisplay(versionState)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: stateIcon(versionState))
                    .font(.title3)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version is \(label)")
                        .font(.callout.weight(.medium))
                    Text("You cannot modify the build or re-submit while in this state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
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
                                Text(item.attributes.state?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unknown")
                                    .font(.callout)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Helpers

    private func stateDisplay(_ state: String) -> (String, Color) {
        switch state {
        case "WAITING_FOR_REVIEW": return ("Waiting for Review", .blue)
        case "IN_REVIEW": return ("In Review", .blue)
        case "PENDING_DEVELOPER_RELEASE": return ("Pending Release", .green)
        case "READY_FOR_SALE": return ("Ready for Sale", .green)
        case "PREPARE_FOR_SUBMISSION": return ("Preparing", .orange)
        case "INVALID_BINARY": return ("Submission Error", .red)
        case "REJECTED": return ("Rejected", .red)
        case "DEVELOPER_REJECTED": return ("Developer Rejected", .orange)
        default: return (state.replacingOccurrences(of: "_", with: " ").capitalized, .secondary)
        }
    }

    private func stateIcon(_ state: String) -> String {
        switch state {
        case "WAITING_FOR_REVIEW": return "clock.badge.checkmark"
        case "IN_REVIEW": return "eye.fill"
        case "PENDING_DEVELOPER_RELEASE": return "checkmark.seal.fill"
        case "READY_FOR_SALE": return "checkmark.circle.fill"
        case "INVALID_BINARY", "REJECTED", "DEVELOPER_REJECTED": return "xmark.circle.fill"
        default: return "info.circle.fill"
        }
    }

    // MARK: - App Icon Loading

    private func loadAppIcon() async -> NSImage? {
        guard let project = appState.activeProject else { return nil }
        return await ProjectAppIconLoader.loadImage(for: project.id, projectPath: project.path)
    }
}
