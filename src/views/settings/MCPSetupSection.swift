import SwiftUI

/// Shared Blitz MCP status plus optional manual Claude Code configuration.
struct MCPSetupSection: View {
    let mcpServer: MCPServerService?

    @State private var serverRunning: Bool = false
    @State private var copied = false

    var body: some View {
        Section("Blitz-Werkzeuge (MCP)") {
            HStack {
                Text("Verbindung")
                Spacer()
                if serverRunning {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Bereit")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("Nicht verbunden")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                copyConfigToClipboard()
            } label: {
                HStack {
                    Text(copied ? "Kopiert" : "Konfiguration für Claude Code kopieren")
                    Spacer()
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Text("Für die manuelle Einrichtung in Claude Code: JSON unter \"mcpServers\" in ~/.claude.json einfügen.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .task {
            await refreshStatus()
        }
    }

    private func refreshStatus() async {
        guard let server = mcpServer else { return }
        serverRunning = await server.isRunning
    }

    private func copyConfigToClipboard() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let config = """
        {
          "blitz-macos": {
            "command": "\(home)/.blitz/blitz-macos-mcp"
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config, forType: .string)

        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}
