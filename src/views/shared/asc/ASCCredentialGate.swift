import SwiftUI

/// Gates ASC content behind credential entry.
/// Shows a spinner while loading, the credential form when unconfigured,
/// and the wrapped content once credentials are present.
struct ASCCredentialGate<Content: View>: View {
    var appState: AppState
    var ascManager: ASCManager
    var projectId: String
    var bundleId: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        if ascManager.isLoadingCredentials {
            VStack(spacing: 12) {
                ProgressView()
                Text("Zugangsdaten werden geprüft …")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if ascManager.credentials == nil {
            ASCCredentialForm(
                appState: appState,
                ascManager: ascManager,
                projectId: projectId,
                bundleId: bundleId
            )
        } else {
            content()
        }
    }
}
