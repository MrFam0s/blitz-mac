import Foundation

/// Display-only translations. Persisted identifiers, Apple values and tool keys
/// must remain unchanged; user-authored content is never passed through a general translator.
enum BlitzDisplayText {
    static func fieldLabel(_ raw: String) -> String {
        let labels: [String: L10n.Message] = [
            "App Name": "App-Name", "Title": "Titel", "Subtitle": "Untertitel",
            "Description": "Beschreibung", "Keywords": "Schlüsselwörter",
            "Support URL": "Support-URL", "Privacy Policy URL": "Datenschutz-URL",
            "Copyright": "Copyright", "Content Rights": "Inhaltsrechte",
            "Primary Category": "Hauptkategorie", "Category": "Kategorie",
            "Age Rating": "Altersfreigabe", "Pricing": "Preisgestaltung",
            "In-App Purchases & Subscriptions": "In-App-Käufe und Abos",
            "Review Contact First Name": "Prüfkontakt: Vorname",
            "Review Contact Last Name": "Prüfkontakt: Nachname",
            "Review Contact Email": "Prüfkontakt: E-Mail",
            "Review Contact Phone": "Prüfkontakt: Telefon",
            "Demo Account Name": "Demokonto: Benutzername",
            "Demo Account Password": "Demokonto: Passwort",
            "App Icon": "App-Symbol", "Mac Screenshots": "Mac-Screenshots",
            "iPhone Screenshots": "iPhone-Screenshots", "iPad Screenshots": "iPad-Screenshots",
            "Privacy Nutrition Labels": "App-Datenschutz", "What's New": "Neuigkeiten",
        ]
        if raw.hasPrefix("What's New (") {
            return L10n.tr("Neuigkeiten") + String(raw.dropFirst("What's New".count))
        }
        return labels[raw].map(L10n.tr) ?? raw
    }

    static func status(_ raw: String) -> String {
        let labels: [String: L10n.Message] = [
            "UNKNOWN": "Unbekannt", "PREPARE_FOR_SUBMISSION": "Entwurf",
            "READY_FOR_REVIEW": "Bereit zur Prüfung", "READY_TO_SUBMIT": "Bereit zur Einreichung",
            "WAITING_FOR_REVIEW": "Wartet auf Prüfung", "IN_REVIEW": "In Prüfung",
            "ACCEPTED": "Akzeptiert", "APPROVED": "Genehmigt", "REJECTED": "Abgelehnt",
            "METADATA_REJECTED": "Metadaten abgelehnt", "DEVELOPER_REJECTED": "Zurückgezogen",
            "INVALID_BINARY": "Build ungültig", "PENDING_DEVELOPER_RELEASE": "Wartet auf Veröffentlichung",
            "PENDING_APPLE_RELEASE": "Wartet auf Veröffentlichung durch Apple",
            "READY_FOR_SALE": "Zur Verteilung freigegeben", "READY_FOR_DISTRIBUTION": "Zur Verteilung freigegeben",
            "PREORDER_READY_FOR_SALE": "Zur Vorbestellung freigegeben",
            "REPLACED_WITH_NEW_VERSION": "Durch neuere Version ersetzt",
            "DEVELOPER_REMOVED_FROM_SALE": "Vom Verkauf zurückgezogen", "REMOVED_FROM_SALE": "Nicht im Verkauf",
            "PROCESSING": "In Verarbeitung", "PROCESSING_FOR_APP_STORE": "Wird für den App Store verarbeitet",
            "PROCESSING_FOR_DISTRIBUTION": "Wird für die Verteilung verarbeitet",
            "COMPLETE": "Abgeschlossen", "IN_PROGRESS": "In Bearbeitung", "CANCELING": "Wird zurückgezogen",
            "CANCELED": "Zurückgezogen", "UNRESOLVED_ISSUES": "Offene Probleme",
            "WAITING_FOR_EXPORT_COMPLIANCE": "Exportprüfung ausstehend",
            "PENDING_CONTRACT": "Vertrag ausstehend", "NOT_APPLICABLE": "Nicht zutreffend",
            "MISSING_METADATA": "Angaben fehlen", "DEVELOPER_ACTION_NEEDED": "Aktion erforderlich",
            "VALID": "Gültig", "INVALID": "Ungültig", "FAILED": "Fehlgeschlagen",
            "EXPIRED": "Abgelaufen", "ACTIVE": "Aktiv", "INACTIVE": "Inaktiv",
            "MANUAL": "Manuell veröffentlichen", "AFTER_APPROVAL": "Nach Freigabe veröffentlichen",
            "SCHEDULED": "Geplant veröffentlichen",
        ]
        return labels[raw.uppercased()].map(L10n.tr) ?? (raw.isEmpty ? L10n.tr("Unbekannt") : raw)
    }

    static func category(_ raw: String) -> String {
        let labels: [String: L10n.Message] = ["GAMES": "Spiele", "UTILITIES": "Dienstprogramme", "PRODUCTIVITY": "Produktivität",
         "SOCIAL_NETWORKING": "Soziale Netze", "PHOTO_AND_VIDEO": "Foto und Video", "MUSIC": "Musik",
         "TRAVEL": "Reisen", "SPORTS": "Sport", "HEALTH_AND_FITNESS": "Gesundheit und Fitness",
         "EDUCATION": "Bildung", "BUSINESS": "Wirtschaft", "FINANCE": "Finanzen", "NEWS": "Nachrichten",
         "FOOD_AND_DRINK": "Essen und Trinken", "LIFESTYLE": "Lifestyle", "SHOPPING": "Shopping",
         "ENTERTAINMENT": "Unterhaltung", "REFERENCE": "Nachschlagewerke", "MEDICAL": "Medizin",
         "NAVIGATION": "Navigation", "WEATHER": "Wetter", "DEVELOPER_TOOLS": "Entwicklerwerkzeuge"]
        return labels[raw].map(L10n.tr) ?? raw
    }

    static func readinessValue(_ value: String, field: String) -> String {
        switch field {
        case "Primary Category", "Category": return category(value)
        case "Content Rights":
            let labels: [String: L10n.Message] = ["DOES_NOT_USE_THIRD_PARTY_CONTENT": "Keine Inhalte Dritter",
                    "USES_THIRD_PARTY_CONTENT": "Inhalte Dritter mit Nutzungsrechten"]
            return labels[value].map(L10n.tr) ?? value
        case "Age Rating", "App Icon", "Pricing":
            let labels: [String: L10n.Message] = ["Configured": "Eingerichtet", "Set": "Festgelegt", "Free": "Kostenlos"]
            return labels[value].map(L10n.tr) ?? value
        case "Mac Screenshots", "iPhone Screenshots", "iPad Screenshots":
            if value.hasSuffix(" screenshot(s)"), let count = Int(value.dropLast(" screenshot(s)".count)) {
                return "\(count) " + (count == 1 ? "Screenshot" : "Screenshots")
            }
        case "What's New":
            if value.hasPrefix("Configured for "), value.hasSuffix(" localization(s)"),
               let count = Int(value.dropFirst("Configured for ".count).dropLast(" localization(s)".count)) {
                return count == 1
                    ? L10n.tr("Für \(count) Sprache ausgefüllt")
                    : L10n.tr("Für \(count) Sprachen ausgefüllt")
            }
        default: break
        }
        return value
    }

    /// The backend hint is an agent instruction, not interface copy. Keep it
    /// intact for the release tools and show only the relevant explanation here.
    static func readinessHint(field: String) -> String? {
        if field == "In-App Purchases & Subscriptions" {
            return L10n.tr("Wähle die Kaufprodukte, die gemeinsam mit dieser App-Version eingereicht werden sollen. Die Übersicht bestätigt noch nicht, dass sie vollständig und der Einreichung zugeordnet sind.")
        }
        if field == "What's New" {
            return L10n.tr("Ergänze unter App-Informationen die Neuigkeiten für jede Sprache dieser Version, bevor du das Update einreichst.")
        }
        if field.hasPrefix("What's New ("), field.hasSuffix(")") {
            let locale = field.dropFirst("What's New (".count).dropLast()
            return L10n.tr("Ergänze unter App-Informationen die Neuigkeiten für die Sprache \(locale), bevor du das Update einreichst.")
        }
        return nil
    }

    static func buildPhase(_ raw: String) -> String {
        let labels: [String: L10n.Message] = ["Setting up signing…": "Signierung wird eingerichtet …", "Archiving…": "Archiv wird erstellt …",
         "Exporting IPA…": "IPA wird exportiert …", "Uploading to App Store Connect…": "Upload zu App Store Connect …",
         "Processing build…": "Build wird verarbeitet …"]
        return labels[raw].map(L10n.tr) ?? raw
    }
}
