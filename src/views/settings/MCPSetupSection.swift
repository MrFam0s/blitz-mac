// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

struct MCPSetupSection: View {
    let mcpServer: MCPServerService?
    var agent: AIAgent = .codex

    @State private var serverRunning: Bool?
    @State private var configuration: MCPIntegrationConfiguration?
    @State private var copied = false
    @State private var showManualSetup = false
    @State private var copyError = false

    var body: some View {
        Section(L10n.tr("Blitz-Neo-Werkzeuge (MCP)")) {
            HStack {
                Text(L10n.tr("Lokaler Dienst"))
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(serverRunning == true ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(serverRunning.map { $0 ? L10n.tr("Bereit") : L10n.tr("Nicht gestartet") } ?? L10n.tr("Wird geprüft …"))
                        .foregroundStyle(.secondary)
                }
            }
            Text(L10n.tr("Stellt Chats die Werkzeuge der laufenden Blitz-Neo-App bereit. Die Einrichtung im Agenten wird separat geprüft."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let configuration {
                LabeledContent(L10n.tr("\(agent.displayName) · Blitz-App"), value: configuration.app.label)
                LabeledContent(L10n.tr("\(agent.displayName) · iPhone & Simulator"), value: configuration.iphone.label)

                if configuration.app == .restricted || configuration.iphone == .restricted {
                    Text(L10n.tr("Die globale Werkzeugauswahl gilt weiterhin. Neue Werkzeuge werden dort nicht automatisch ergänzt; die Freigaben des Agenten gelten zusätzlich."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup(L10n.tr("Manuelle Einrichtung"), isExpanded: $showManualSetup) {
                    Text(manualInstructions(configuration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if configuration.app == .missing {
                        Button(copied ? L10n.tr("Kopiert") : L10n.tr("Blitz-App-Konfiguration für \(agent.displayName) kopieren"),
                               systemImage: copied ? "checkmark" : "doc.on.doc") {
                            let snippet = MCPIntegrationConfiguration.manualSnippet(agent: agent, helperPath: BlitzPaths.mcpHelper.path)
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(snippet, forType: .string)
                            copyError = !copied
                        }
                        .buttonStyle(.plain)
                    } else if configuration.app != .unreadable {
                        Button(L10n.tr("Konfigurationsdatei öffnen"), systemImage: "doc.text") {
                            NSWorkspace.shared.open(configuration.file)
                        }
                        .buttonStyle(.plain)
                    }
                    if copyError {
                        Text(L10n.tr("Die Konfiguration konnte nicht kopiert werden."))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .task(id: agent.rawValue) { await refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshStatus() }
        }
    }

    private func refreshStatus() async {
        serverRunning = await mcpServer?.isRunning ?? false
        configuration = MCPIntegrationConfiguration.load(agent: agent)
        copied = false
        copyError = false
    }

    private func manualInstructions(_ configuration: MCPIntegrationConfiguration) -> String {
        if configuration.app == .unreadable {
            return L10n.tr("Die globale Konfiguration konnte nicht gelesen werden. Bitte in \(agent.displayName) prüfen. Es wurde nichts geändert.")
        }
        if configuration.app != .missing {
            return L10n.tr("Der globale Blitz-Eintrag ist bereits vorhanden. Bitte keinen zweiten Eintrag anlegen. Änderungen und die Werkzeugauswahl verwaltest du in \(configuration.file.path).")
        }
        let target = agent == .codex ? L10n.tr("als eigenen Abschnitt") : L10n.tr("unter \"\(agent == .claudeCode ? "mcpServers" : "mcp")\"")
        return L10n.tr("Nur für die manuelle Einrichtung der Blitz-App: \(target) in \(configuration.file.path) einfügen. Vorher vorhandene Projekt- oder Plugin-Konfigurationen prüfen, damit kein zweiter Eintrag entsteht. Blitz-Projekte können die Werkzeuge bereits bereitstellen.")
    }
}
