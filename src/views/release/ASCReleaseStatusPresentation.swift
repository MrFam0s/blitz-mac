import SwiftUI

struct ASCStatusPresentation: Equatable {
    enum Tone: Equatable { case neutral, positive, warning, review, rejected }

    let label: String
    let symbol: String
    let tone: Tone
    let help: String
}

/// Version approval and current storefront availability are different facts.
enum ASCReleaseStatusPresentation {
    static func version(_ version: ASCAppStoreVersion?, distributionReadyVersionID: String?) -> ASCStatusPresentation {
        guard let version else {
            return .init(label: "Unbekannt", symbol: "questionmark.circle", tone: .neutral, help: "Der Versionsstatus ist nicht verfügbar.")
        }
        let state = ASCReleaseStatus.normalize(version.attributes.effectiveState)
        if ASCReleaseStatus.isLive(state) {
            if version.id == distributionReadyVersionID {
                return .init(label: "Zur Verteilung freigegeben", symbol: "checkmark.seal", tone: .neutral,
                             help: "Apple hat diese Version freigegeben. Die Verfügbarkeit im Store wird separat geprüft.")
            }
            return .init(label: "Früher veröffentlicht", symbol: "clock.arrow.circlepath", tone: .neutral,
                         help: "Dies ist eine frühere Veröffentlichung, nicht die aktuelle App-Store-Version.")
        }
        let label: String
        let symbol: String
        let tone: ASCStatusPresentation.Tone
        switch state {
        case "REPLACED_WITH_NEW_VERSION":
            label = "Früher veröffentlicht"; symbol = "clock.arrow.circlepath"; tone = .neutral
        case "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE":
            label = "Nicht mehr im Verkauf"; symbol = "minus.circle"; tone = .neutral
        case "PREPARE_FOR_SUBMISSION":
            label = "Entwurf"; symbol = "doc.text"; tone = .warning
        case "DEVELOPER_REJECTED":
            label = "Zurückgezogen"; symbol = "arrow.uturn.backward.circle"; tone = .warning
        case "INVALID_BINARY":
            label = "Einreichungsfehler"; symbol = "exclamationmark.circle"; tone = .rejected
        case "REJECTED", "METADATA_REJECTED":
            label = state == "REJECTED" ? "Abgelehnt" : "Metadaten abgelehnt"
            symbol = "xmark.circle"; tone = .rejected
        case "IN_REVIEW":
            label = "In Prüfung"; symbol = "eye"; tone = .review
        case "WAITING_FOR_REVIEW":
            label = "Wartet auf Prüfung"; symbol = "clock"; tone = .review
        case "ACCEPTED", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE":
            label = state == "ACCEPTED" ? "Akzeptiert" : "Veröffentlichung ausstehend"
            symbol = "clock.badge.checkmark"; tone = .review
        case "PROCESSING", "PROCESSING_FOR_APP_STORE", "PROCESSING_FOR_DISTRIBUTION":
            label = "In Verarbeitung"; symbol = "hourglass"; tone = .review
        default:
            label = BlitzDisplayText.status(state)
            symbol = "info.circle"; tone = .neutral
        }
        return .init(label: label, symbol: symbol, tone: tone, help: "Apple-Versionsstatus: \(BlitzDisplayText.status(state))")
    }

    static func store(
        distributionReadyVersionID: String?,
        liveVersionID: String?,
        availability: ASCStoreAvailability?,
        isLoading: Bool,
        failed: Bool
    ) -> ASCStatusPresentation {
        if isLoading {
            return .init(label: "Verfügbarkeit wird geprüft …", symbol: "clock", tone: .neutral,
                         help: "Die aktuelle Verfügbarkeit im App Store wird geprüft.")
        }
        if failed {
            return .init(label: "Verfügbarkeit unbekannt", symbol: "questionmark.circle", tone: .neutral,
                         help: "Die Store-Verfügbarkeit konnte nicht geprüft werden. Aktualisiere diese Rubrik, um es erneut zu versuchen.")
        }
        if availability == .unavailable {
            return .init(label: "Nicht im App Store", symbol: "minus.circle", tone: .neutral,
                         help: "Diese App ist aktuell nicht im App Store verfügbar.")
        }
        if availability == .available, let liveVersionID, liveVersionID == distributionReadyVersionID {
            return .init(label: "Im App Store verfügbar", symbol: "checkmark.seal.fill", tone: .positive,
                         help: "Die aktuelle App-Store-Verfügbarkeit dieser Version ist bestätigt.")
        }
        if availability == nil {
            return .init(label: "Verfügbarkeit unbekannt", symbol: "questionmark.circle", tone: .neutral,
                         help: "Die aktuelle App-Store-Verfügbarkeit wurde noch nicht bestätigt.")
        }
        return .init(label: "Keine veröffentlichte Version", symbol: "minus.circle", tone: .neutral,
                     help: "Für diese Plattform ist keine aktuelle veröffentlichte Version verfügbar.")
    }
}

extension ASCStatusPresentation.Tone {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .positive: return .green
        case .warning: return .orange
        case .review: return .blue
        case .rejected: return .red
        }
    }
}

struct ASCStatusBadge: View {
    let presentation: ASCStatusPresentation

    var body: some View {
        Text(presentation.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(presentation.tone.color.opacity(0.12))
            .foregroundStyle(presentation.tone.color)
            .clipShape(Capsule())
            .help(presentation.help)
    }
}

struct ASCVersionStatusBadges: View {
    let asc: ASCManager
    let version: ASCAppStoreVersion

    var body: some View {
        BlitzFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
            ASCStatusBadge(presentation: ASCReleaseStatusPresentation.version(
                version, distributionReadyVersionID: asc.distributionReadyVersion?.id
            ))
            if ASCReleaseStatus.isLive(version.attributes.effectiveState),
               version.id == asc.distributionReadyVersion?.id {
                ASCStatusBadge(presentation: ASCReleaseStatusPresentation.store(
                    distributionReadyVersionID: asc.distributionReadyVersion?.id,
                    liveVersionID: asc.storeLiveVersion?.id,
                    availability: asc.confirmedStoreAvailability,
                    isLoading: asc.isStoreAvailabilityLoading,
                    failed: asc.storeAvailabilityFailed
                ))
            }
        }
    }
}
