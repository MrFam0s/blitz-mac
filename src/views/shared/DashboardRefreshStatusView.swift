import SwiftUI

/// Shared by the dashboard and the isolated UI verification harness.
struct DashboardRefreshStatusView: View {
    let issueTitle: String?
    let issueMessage: String?
    let needsSettings: Bool
    let isShowingSavedData: Bool
    let hasLoadedSummary: Bool
    let isLoading: Bool
    let loadingText: String
    let refreshedAt: Date?
    let retry: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let issueTitle {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issueTitle).font(.callout.weight(.semibold))
                            Text(issueMessage ?? "").font(.callout).foregroundStyle(.secondary)
                            if isShowingSavedData {
                                Text(L10n.tr("Gespeicherte Daten werden angezeigt. Der aktuelle Status konnte nicht geprüft werden."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { issueActions }.fixedSize()
                        VStack(alignment: .leading, spacing: 8) { issueActions }
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if isLoading {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(loadingText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var issueActions: some View {
        if needsSettings { Button(L10n.tr("Einstellungen"), action: openSettings) }
        Button(L10n.tr("Erneut versuchen"), action: retry).disabled(isLoading)
    }

}
