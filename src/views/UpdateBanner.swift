// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

// MARK: - Full-screen overlay

/// Full-screen update card that blocks the main window UI when an update is in progress.
struct UpdateOverlay: View {
    @Bindable var autoUpdate: AutoUpdateManager

    var body: some View {
        ZStack {
            // Dim background — blocks interaction with content beneath
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            UpdateCardContent(autoUpdate: autoUpdate)
                .frame(width: 512)
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        }
    }
}

/// Reusable update card content used by both UpdateOverlay and UpdateSettingsRow sheet.
struct UpdateCardContent: View {
    @Bindable var autoUpdate: AutoUpdateManager

    @ViewBuilder
    var body: some View {
        switch autoUpdate.state {
        case .available(let version, let notes):
            VStack(alignment: .leading, spacing: 16) {
                BlitzSetupHeader("Blitz Neo aktualisieren", subtitle: "Version \(version) ist verfügbar.")

                if !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }

                Divider()
                HStack {
                    Button("Später") {
                        autoUpdate.dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Jetzt aktualisieren") {
                        Task { await autoUpdate.performUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

        case .downloading(let percent):
            VStack(alignment: .leading, spacing: 16) {
                BlitzSetupHeader("Update wird geladen", subtitle: percent >= 0
                    ? "\(percent) % abgeschlossen"
                    : "Die neue Version von Blitz Neo wird heruntergeladen.")

                if percent >= 0 {
                    ProgressView(value: Double(percent), total: 100)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }
            }

        case .installing:
            VStack(alignment: .leading, spacing: 16) {
                BlitzSetupHeader("Update wird installiert", subtitle: "Blitz Neo startet anschließend automatisch neu.")

                ProgressView()
                    .frame(maxWidth: .infinity)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 16) {
                Label("Update fehlgeschlagen", systemImage: "exclamationmark.triangle")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                ScrollView {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)

                Divider()
                HStack {
                    Button("Schließen") {
                        autoUpdate.dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Erneut versuchen") {
                        Task { await autoUpdate.performUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

        default:
            EmptyView()
        }
    }
}

// MARK: - Settings row with sheet

/// Inline row for the Settings "Updates" section.
/// Shows status + "Nach veröffentlichten Updates suchen" or "Update ansehen" button.
/// Active update/download/install states are shown in a closable sheet reusing UpdateOverlay.
struct UpdateSettingsRow: View {
    @Bindable var autoUpdate: AutoUpdateManager
    @State private var showUpdateSheet = false

    var body: some View {
        switch autoUpdate.state {
        case .idle:
            Button("Nach veröffentlichten Updates suchen") {
                Task { await autoUpdate.checkForUpdate() }
            }

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Updates werden geprüft …")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .upToDate:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Kein neueres veröffentlichtes Update")
                    .font(.callout)
                Spacer()
                Button("Erneut prüfen") {
                    Task { await autoUpdate.checkForUpdate() }
                }
                .controlSize(.small)
            }

        case .unavailable(let message), .checkFailed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: checkFailed ? "exclamationmark.triangle" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Erneut prüfen") {
                    Task { await autoUpdate.checkForUpdate() }
                }
                .controlSize(.small)
            }

        case .available(let version, _):
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Text("Update verfügbar")
                    .font(.callout)
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Update ansehen") {
                    showUpdateSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .sheet(isPresented: $showUpdateSheet) {
                updateSheet
            }

        case .downloading, .installing, .failed:
            HStack(spacing: 8) {
                if case .failed = autoUpdate.state {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(statusLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Ansehen") {
                    showUpdateSheet = true
                }
                .controlSize(.small)
            }
            .sheet(isPresented: $showUpdateSheet) {
                updateSheet
            }
            .onAppear { showUpdateSheet = true }
        }
    }

    private var checkFailed: Bool {
        if case .checkFailed = autoUpdate.state { return true }
        return false
    }

    private var statusLabel: String {
        switch autoUpdate.state {
        case .downloading: return "Wird geladen …"
        case .installing: return "Wird installiert …"
        case .failed: return "Update fehlgeschlagen"
        default: return ""
        }
    }

    private var updateSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            UpdateCardContent(autoUpdate: autoUpdate)

            if hasActiveUpdate {
                Divider()
                HStack {
                    Button("Schließen") {
                        showUpdateSheet = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var hasActiveUpdate: Bool {
        switch autoUpdate.state {
        case .downloading, .installing: return true
        default: return false
        }
    }
}
