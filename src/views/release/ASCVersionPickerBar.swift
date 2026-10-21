import SwiftUI

struct ASCVersionPickerBar<Content: View>: View {
    var asc: ASCManager
    var selection: Binding<String>
    var onCreateDraft: (() -> Void)? = nil
    var onPublishUpdate: (() -> Void)? = nil
    var appStoreURL: URL? = nil
    var refreshTab: AppTab? = nil
    var refreshHelpText: String = "Refresh this tab"
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                BlitzFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                    versionSelection
                    content
                }
                toolbarTools
                    .fixedSize()
            }

            // Keep release operations together below the version context. At
            // especially narrow widths they may wrap, but never mix with tools.
            if onCreateDraft != nil || onPublishUpdate != nil {
                BlitzFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                    releaseActions
                }
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }

    @ViewBuilder private var toolbarTools: some View {
        if appStoreURL != nil || refreshTab != nil {
            HStack(spacing: 10) {
                if let appStoreURL {
                    Link(destination: appStoreURL) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 20, height: 24)
                    }
                    .accessibilityLabel("Open in App Store Connect")
                    .help("Open in App Store Connect")
                }
                if let refreshTab {
                    ASCTabRefreshButton(asc: asc, tab: refreshTab, helpText: refreshHelpText)
                        .frame(width: 20, height: 24)
                }
            }
            .foregroundStyle(.secondary)
            .tint(.secondary)
        }
    }

    @ViewBuilder private var versionSelection: some View {
        if !asc.appStoreVersions.isEmpty {
            Picker("Version", selection: selection) {
                ForEach(asc.appStoreVersions) { version in
                    Text("Version \(version.attributes.versionString)").tag(version.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Version")
            .fixedSize(horizontal: true, vertical: true)
            .frame(height: 24, alignment: .leading)
        }
        if let version = asc.selectedVersion { stateBadge(version.attributes.appStoreState ?? "") }
    }

    @ViewBuilder private var releaseActions: some View {
        if let onCreateDraft {
            Button("Versionsentwurf anlegen", action: onCreateDraft)
                .buttonStyle(.bordered)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .disabled(!asc.canCreateVersion || asc.newVersionCreationBlocker != nil)
                .help(asc.newVersionCreationBlocker == nil
                      ? "Entwurf zum Bearbeiten von Texten und Medien anlegen. Es wird nichts eingereicht."
                      : "Es gibt bereits eine unveröffentlichte Version. Wähle sie zum Bearbeiten aus.")
        }
        if let onPublishUpdate {
            if asc.canStartReleaseAutomation {
                publishUpdateButton(action: onPublishUpdate)
                    .buttonStyle(.borderedProminent)
            } else {
                publishUpdateButton(action: onPublishUpdate)
                    .buttonStyle(.bordered)
                    .disabled(true)
            }
        }
    }

    private func publishUpdateButton(action: @escaping () -> Void) -> some View {
        Button("Update automatisch veröffentlichen", action: action)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .help("Öffnet den Ablauf für Build, Changelog und Einreichung. Ein vorhandener bearbeitbarer Entwurf kann weiterverwendet werden.")
    }

    private func stateBadge(_ state: String) -> some View {
        let normalizedState = ASCReleaseStatus.normalize(state)
        let color: Color
        if ASCReleaseStatus.isLive(normalizedState) {
            color = .green
        } else if ASCReleaseStatus.isEditable(normalizedState) {
            color = .orange
        } else if ASCReleaseStatus.pendingReviewStates.contains(normalizedState) {
            color = .blue
        } else if ASCReleaseStatus.rejectedStates.contains(normalizedState) {
            color = .red
        } else {
            color = .secondary
        }

        return Text(normalizedState.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .frame(height: 24)
    }
}

extension ASCVersionPickerBar where Content == EmptyView {
    init(
        asc: ASCManager,
        selection: Binding<String>,
        onCreateDraft: (() -> Void)? = nil,
        onPublishUpdate: (() -> Void)? = nil,
        appStoreURL: URL? = nil,
        refreshTab: AppTab? = nil,
        refreshHelpText: String = "Refresh this tab"
    ) {
        self.asc = asc
        self.selection = selection
        self.onCreateDraft = onCreateDraft
        self.onPublishUpdate = onPublishUpdate
        self.appStoreURL = appStoreURL
        self.refreshTab = refreshTab
        self.refreshHelpText = refreshHelpText
        self.content = EmptyView()
    }
}
