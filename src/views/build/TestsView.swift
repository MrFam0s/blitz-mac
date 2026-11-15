// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

struct TestsView: View {
    @Bindable var appState: AppState

    private var iphoneMCPConfigured: Bool {
        guard let projectId = appState.activeProjectId else { return false }
        let mcpFile = ProjectStorage().baseDirectory
            .appendingPathComponent(projectId)
            .appendingPathComponent(".mcp.json")
        guard let data = try? Data(contentsOf: mcpFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return false }
        return servers["blitz-iphone"] != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                hero
                statusBadge
                ExampleCard(
                    title: "Funktion ergänzen und testen",
                    icon: "person.badge.plus",
                    prompt: "Ergänze Registrierung und Anmeldung und teste anschließend den gesamten Ablauf im Simulator.",
                    preview: "Der Agent entwickelt die Funktion und prüft anschließend den gesamten Ablauf im Simulator: Er tippt, gibt Daten ein und kontrolliert jede Ansicht.",
                    detail: detailSignup
                )
                ExampleCard(
                    title: "App-Store-Screenshots aufnehmen",
                    icon: "camera.viewfinder",
                    prompt: "Erstelle zehn App-Store-Screenshots in unterschiedlichen Ansichten der App und lade sie hoch.",
                    preview: "Der Agent öffnet verschiedene Ansichten der App, nimmt Screenshots auf und lädt sie in App Store Connect hoch.",
                    detail: detailScreenshots
                )
                ExampleCard(
                    title: "Abos einrichten und testen",
                    icon: "creditcard",
                    prompt: "Erstelle ein Abo, ergänze eine Kaufansicht und teste den Kaufablauf.",
                    preview: "Der Agent erstellt ein Abo in App Store Connect, ergänzt eine Kaufansicht im Projekt und testet den Kaufablauf auf einem Gerät.",
                    detail: detailSubscriptions
                )
            }
            .blitzPagePadding()
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tests mit KI-Agenten automatisieren", systemImage: "sparkles")
                .font(BlitzLayout.pageTitle)
                .fixedSize(horizontal: false, vertical: true)

            Text("Im Projektordner von Blitz Neo kannst du Agenten beauftragen, Funktionen auf iPhones zu testen und Fehler zu finden. Über das **iPhone-MCP** von Blitz Neo kann dein Agent tippen, wischen und Text eingeben – sowohl im Simulator als auch auf einem echten iPhone.")
                .font(BlitzLayout.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Status

    private var statusBadge: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(iphoneMCPConfigured ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(iphoneMCPConfigured
                 ? "iPhone-MCP ist für dieses Projekt eingerichtet"
                 : "iPhone-MCP nicht gefunden – öffne ein Projekt, um zu beginnen")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Details

    private let detailSignup = """
    Der Agent erstellt die Ansichten, verbindet sie mit deinem Backend und prüft den Ablauf über **iPhone-MCP**:

    1. App starten und die Registrierung öffnen
    2. Test-E-Mail-Adresse und Passwort mit `device_action` eingeben
    3. Auf „Registrieren“ tippen und prüfen, ob die Startansicht geladen wird
    4. Auf „Abmelden“ tippen und die Rückkehr zur Anmeldung prüfen
    5. Mit denselben Zugangsdaten erneut anmelden
    6. Mit `describe_screen` prüfen, ob die Anmeldung erfolgreich war

    Schlägt ein Schritt fehl, sieht der Agent den tatsächlichen Bildschirm und kann den Fehler direkt untersuchen.
    """

    private let detailScreenshots = """
    Der Agent bereitet die App vor jeder Aufnahme über **iPhone-MCP** vor:

    1. Die gewünschte Ansicht öffnen, scrollen und passende Daten eingeben
    2. Mit `get_screenshot` jede Ansicht in voller Auflösung aufnehmen
    3. Mit `screenshots_switch_localization` → `screenshots_put_track_slot` / `screenshots_remove_track_slot` / `screenshots_reorder_track` → `screenshots_save` die Screenshots in App Store Connect hochladen

    So erhältst du aussagekräftige Screenshots, ohne den Simulator selbst bedienen zu müssen.
    """

    private let detailSubscriptions = """
    Der Agent begleitet den gesamten Ablauf – von App Store Connect bis zum Test auf dem Gerät:

    1. Mit `asc_create_subscription` eine Abo-Gruppe und die Preise einrichten
    2. Eine Kaufansicht im Projekt ergänzen, die bei der passenden Benutzeraktion erscheint
    3. Die App erstellen und auf einem **echten Gerät** mit einem Sandbox-Apple-Account installieren
    4. Über **iPhone-MCP** zur Kaufansicht navigieren
    5. Auf „Abonnieren“ tippen, um den Testkauf in der Sandbox zu starten
    6. Prüfen, ob die Premium-Inhalte nach dem Kauf freigeschaltet sind

    **Hinweis:** Erstelle einen Sandbox-Apple-Account unter App Store Connect → Benutzer und Zugriffsrechte → Sandbox und melde dich damit auf dem Testgerät an. Der Agent übernimmt die weiteren Schritte.
    """
}

// MARK: - Example Card

private struct ExampleCard: View {
    let title: String
    let icon: String
    let prompt: String
    let preview: String
    let detail: String

    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(BlitzLayout.sectionTitle)
                .fixedSize(horizontal: false, vertical: true)

            // Prompt block
            HStack(alignment: .top, spacing: 8) {
                Text(prompt)
                    .font(.system(size: 13, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Anfrage kopieren")
            }

            // Preview text
            Text(preview)
                .font(BlitzLayout.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Expand/collapse
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(expanded ? "Details ausblenden" : "So funktioniert es")
                        .font(.callout.weight(.medium))
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            // Detail section — uses disclosure group pattern with clipping
            if expanded {
                Text(LocalizedStringKey(detail))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .clipped()
        .padding(BlitzLayout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }
}
