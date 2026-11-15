// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

struct TerminalToolsSection: View {
    @Bindable var settings: SettingsService
    @Environment(\.scenePhase) private var scenePhase

    @State private var tools = TerminalToolInstallation.inspect()
    @State private var shortcutState = TerminalShellShortcutState.unconfigured
    @State private var copiedTool: String?
    @State private var shellError: String?

    var body: some View {
        Section("Terminal-Werkzeuge") {
            ForEach(tools) { tool in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(tool.tool.title)
                        Spacer(minLength: 8)
                        Text(statusText(tool.availability))
                            .font(.callout)
                            .foregroundStyle(tool.availability == .installed ? .secondary : Color.orange)
                    }
                    Text(tool.tool.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if tool.availability == .installed {
                        Button {
                            NSPasteboard.general.clearContents()
                            copiedTool = NSPasteboard.general.setString(tool.shellCommand, forType: .string) ? tool.id : nil
                        } label: {
                            Label(copiedTool == tool.id ? "Befehl kopiert" : "Befehl kopieren",
                                  systemImage: copiedTool == tool.id ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help(tool.executableURL.path)
                    }
                }
                .padding(.vertical, 2)
            }

            Text("Die Befehle werden mit vollständigem Pfad kopiert. Eine zusätzliche Shell-Einrichtung ist dafür nicht nötig.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Kurze Befehle im Terminal") {
                shellShortcuts
            }
            .font(.callout)
        }
        .task { refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        .task(id: copiedTool) {
            guard copiedTool != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedTool = nil
        }
    }

    private var shellShortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            let service = ShellIntegrationService()
            Text("Optional kann Blitz Neo die kurzen Befehle `asc` und `blitz-neo` in neuen Terminals einrichten. Bereits vorhandene Aufrufpfade bleiben auch ohne diesen Eintrag nutzbar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if shortcutState == .configured {
                Text("Blitz-Neo-Eintrag eingerichtet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if shortcutState == .incomplete {
                Text("Der gespeicherte Shell-Eintrag ist unvollständig.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if service.isSupported && shortcutState != .configured {
                Button(shortcutState == .incomplete ? "Shell-Eintrag reparieren" : "Kurze Befehle einrichten") {
                    updateShellShortcuts(enabled: true)
                }
                .buttonStyle(.borderless)
                Text("Ergänzt einen Blitz-Neo-Eintrag in \(service.targetRCFileLabel).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if shortcutState != .unconfigured {
                Button("Blitz-Neo-Shell-Eintrag entfernen") {
                    updateShellShortcuts(enabled: false)
                }
                .buttonStyle(.borderless)
            }

            if let shellError {
                Text(shellError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private func statusText(_ status: TerminalToolInstallation.Availability) -> String {
        switch status {
        case .installed: return "Installiert"
        case .incomplete: return "Installation unvollständig"
        case .missing: return "Nicht installiert"
        }
    }

    private func refresh() {
        tools = TerminalToolInstallation.inspect()
        shortcutState = TerminalShellShortcutState.inspect(enabled: settings.enableASCShellIntegration)
    }

    private func updateShellShortcuts(enabled: Bool) {
        shellError = nil
        do {
            try settings.setASCShellIntegrationEnabled(enabled)
        } catch {
            shellError = error.localizedDescription
        }
        refresh()
    }
}
