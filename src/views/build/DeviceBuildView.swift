import SwiftUI

struct DeviceBuildView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Physical Device Build")
                .font(BlitzLayout.pageTitle)
            Text("Connect an iOS device via USB to build and run.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .blitzPagePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
