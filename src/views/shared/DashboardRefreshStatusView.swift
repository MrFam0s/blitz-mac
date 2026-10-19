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
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issueTitle).font(.callout.weight(.semibold))
                        Text(issueMessage ?? "").font(.callout).foregroundStyle(.secondary)
                        if isShowingSavedData {
                            Text("Showing saved data; current status could not be checked.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if needsSettings { Button("Settings", action: openSettings) }
                    Button("Retry", action: retry).disabled(isLoading)
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 5) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                    Text(loadingText)
                } else if let refreshedAt {
                    Text(isShowingSavedData ? "Saved app list updated" : "App list updated")
                    Text(refreshedAt, style: .relative)
                    Text("ago")
                } else if hasLoadedSummary {
                    Text("Saved app list; last update unknown")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
