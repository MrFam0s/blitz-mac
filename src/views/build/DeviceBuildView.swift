// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

struct DeviceBuildView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Build auf einem Gerät")
                .font(BlitzLayout.pageTitle)
            Text("Verbinde ein iOS-Gerät per USB, um die App darauf zu erstellen und auszuführen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .blitzPagePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
