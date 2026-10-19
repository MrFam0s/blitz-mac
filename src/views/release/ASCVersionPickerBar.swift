import SwiftUI

struct ASCVersionPickerBar<Content: View>: View {
    var asc: ASCManager
    var selection: Binding<String>
    var onCreateDraft: (() -> Void)? = nil
    var onPublishUpdate: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                versionSelection
                Spacer()
                releaseActions
                content
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) { versionSelection; Spacer(); content }
                HStack(spacing: 10) { Spacer(); releaseActions }
            }
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
            .frame(width: 190)
        }
        if let version = asc.selectedVersion { stateBadge(version.attributes.appStoreState ?? "") }
    }

    @ViewBuilder private var releaseActions: some View {
        if let onCreateDraft {
            Button("Versionsentwurf anlegen", action: onCreateDraft)
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(!asc.canCreateVersion || asc.newVersionCreationBlocker != nil)
                .help(asc.newVersionCreationBlocker == nil
                      ? "Entwurf zum Bearbeiten von Texten und Medien anlegen. Es wird nichts eingereicht."
                      : "Es gibt bereits eine unveröffentlichte Version. Wähle sie zum Bearbeiten aus.")
        }
        if let onPublishUpdate {
            Button("Update automatisch veröffentlichen", action: onPublishUpdate)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(!asc.canStartReleaseAutomation)
                .help("Öffnet den Ablauf für Build, Changelog und Einreichung. Ein vorhandener bearbeitbarer Entwurf kann weiterverwendet werden.")
        }
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
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

extension ASCVersionPickerBar where Content == EmptyView {
    init(asc: ASCManager, selection: Binding<String>) {
        self.asc = asc
        self.selection = selection
        self.content = EmptyView()
    }
}
