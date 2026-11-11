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
            return .init(label: "Unknown", symbol: "questionmark.circle", tone: .neutral, help: "Version status is not available.")
        }
        let state = ASCReleaseStatus.normalize(version.attributes.effectiveState)
        if ASCReleaseStatus.isLive(state) {
            if version.id == distributionReadyVersionID {
                return .init(label: "Approved for distribution", symbol: "checkmark.seal", tone: .neutral,
                             help: "Apple has approved this version. Store availability is checked separately.")
            }
            return .init(label: "Previously released", symbol: "clock.arrow.circlepath", tone: .neutral,
                         help: "This is a previous release, not the current App Store version.")
        }
        let label: String
        let symbol: String
        let tone: ASCStatusPresentation.Tone
        switch state {
        case "REPLACED_WITH_NEW_VERSION":
            label = "Previously released"; symbol = "clock.arrow.circlepath"; tone = .neutral
        case "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE":
            label = "Removed from distribution"; symbol = "minus.circle"; tone = .neutral
        case "PREPARE_FOR_SUBMISSION":
            label = "Draft"; symbol = "doc.text"; tone = .warning
        case "DEVELOPER_REJECTED":
            label = "Developer Rejected"; symbol = "arrow.uturn.backward.circle"; tone = .warning
        case "INVALID_BINARY":
            label = "Submission Error"; symbol = "exclamationmark.circle"; tone = .rejected
        case "REJECTED", "METADATA_REJECTED":
            label = state == "REJECTED" ? "Rejected" : "Metadata Rejected"
            symbol = "xmark.circle"; tone = .rejected
        case "IN_REVIEW":
            label = "In Review"; symbol = "eye"; tone = .review
        case "WAITING_FOR_REVIEW":
            label = "Waiting for Review"; symbol = "clock"; tone = .review
        case "ACCEPTED", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE":
            label = state == "ACCEPTED" ? "Accepted" : "Pending Release"
            symbol = "clock.badge.checkmark"; tone = .review
        case "PROCESSING", "PROCESSING_FOR_APP_STORE", "PROCESSING_FOR_DISTRIBUTION":
            label = "Processing"; symbol = "hourglass"; tone = .review
        default:
            label = state.isEmpty ? "Unknown" : state.replacingOccurrences(of: "_", with: " ").capitalized
            symbol = "info.circle"; tone = .neutral
        }
        return .init(label: label, symbol: symbol, tone: tone, help: "Apple version status: \(state.isEmpty ? "unknown" : state)")
    }

    static func store(
        distributionReadyVersionID: String?,
        liveVersionID: String?,
        availability: ASCStoreAvailability?,
        isLoading: Bool,
        failed: Bool
    ) -> ASCStatusPresentation {
        if isLoading {
            return .init(label: "Checking availability…", symbol: "clock", tone: .neutral,
                         help: "Checking current App Store availability.")
        }
        if failed {
            return .init(label: "Availability unknown", symbol: "questionmark.circle", tone: .neutral,
                         help: "Store availability could not be checked. Refresh this tab to try again.")
        }
        if availability == .unavailable {
            return .init(label: "Not on the App Store", symbol: "minus.circle", tone: .neutral,
                         help: "This app is currently unavailable on the App Store.")
        }
        if availability == .available, let liveVersionID, liveVersionID == distributionReadyVersionID {
            return .init(label: "Live on the App Store", symbol: "checkmark.seal.fill", tone: .positive,
                         help: "Current App Store availability is confirmed for this release.")
        }
        if availability == nil {
            return .init(label: "Availability unknown", symbol: "questionmark.circle", tone: .neutral,
                         help: "Current App Store availability has not been confirmed.")
        }
        return .init(label: "No live version", symbol: "minus.circle", tone: .neutral,
                     help: "No current released version is available for this platform.")
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
