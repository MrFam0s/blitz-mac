import SwiftUI

enum TestFlightPresentation {
    static func status(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return L10n.tr("Nicht verfügbar") }
        switch value {
        case "PROCESSING": return L10n.tr("Wird verarbeitet")
        case "FAILED": return L10n.tr("Fehlgeschlagen")
        case "INVALID": return L10n.tr("Ungültig")
        case "VALID": return L10n.tr("Gültig")
        case "EXPIRED": return L10n.tr("Abgelaufen")
        case "MISSING_EXPORT_COMPLIANCE": return L10n.tr("Exportangaben fehlen")
        case "IN_EXPORT_COMPLIANCE_REVIEW": return L10n.tr("Exportangaben werden geprüft")
        case "WAITING_FOR_EXPORT_COMPLIANCE": return L10n.tr("Wartet auf Exportprüfung")
        case "READY_FOR_BETA_SUBMISSION": return L10n.tr("Bereit zur Beta-Einreichung")
        case "WAITING_FOR_BETA_REVIEW": return L10n.tr("Wartet auf Beta-Prüfung")
        case "IN_BETA_REVIEW": return L10n.tr("In Beta-Prüfung")
        case "BETA_REJECTED": return L10n.tr("Betatest abgelehnt")
        case "BETA_APPROVED": return L10n.tr("Für Betatest freigegeben")
        case "READY_FOR_BETA_TESTING", "READY_FOR_TESTING": return L10n.tr("Bereit zum Testen")
        case "IN_BETA_TESTING": return L10n.tr("Im Betatest")
        case "NOT_INVITED": return L10n.tr("Nicht eingeladen")
        case "INVITED": return L10n.tr("Eingeladen")
        case "ACCEPTED": return L10n.tr("Angenommen")
        case "INSTALLED": return L10n.tr("Installiert")
        case "REVOKED": return L10n.tr("Widerrufen")
        case "EMAIL": return L10n.tr("E-Mail")
        case "PUBLIC_LINK": return L10n.tr("Öffentlicher Link")
        default: return value
        }
    }

    static func platform(_ value: String?) -> String {
        switch value {
        case "IOS": return "iOS"
        case "MAC_OS": return "macOS"
        case "TV_OS": return "tvOS"
        case "VISION_OS": return "visionOS"
        case "WATCH_OS": return "watchOS"
        case .some(let value) where !value.isEmpty: return value
        default: return L10n.tr("Plattform unbekannt")
        }
    }

    static func buildLabel(_ build: ASCBuild) -> String {
        let version = build.preReleaseVersion?.attributes.version ?? L10n.tr("Version unbekannt")
        return "\(version) (\(build.attributes.version)) · \(platform(build.preReleaseVersion?.attributes.platform))"
    }

    static func expiration(_ build: ASCBuild, now: Date = Date()) -> String {
        if build.attributes.expired == true { return L10n.tr("Abgelaufen") }
        if let raw = build.attributes.expirationDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: raw)
            formatter.formatOptions = [.withInternetDateTime]
            if let date = fractional ?? formatter.date(from: raw) {
                return date <= now ? L10n.tr("Abgelaufen") : L10n.tr("Nicht abgelaufen")
            }
        }
        return build.attributes.expired == false ? L10n.tr("Nicht abgelaufen") : L10n.tr("Nicht verfügbar")
    }

    static func groupType(_ group: ASCBetaGroup) -> String {
        switch group.attributes.isInternalGroup {
        case true: L10n.tr("Intern")
        case false: L10n.tr("Extern")
        default: L10n.tr("Typ unbekannt")
        }
    }
}

struct TestFlightDetailStatus: View {
    var isLoading: Bool
    var error: String?
    var hasData: Bool
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(hasData ? L10n.tr("Details werden aktualisiert …") : L10n.tr("Details werden geladen …"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error {
                Label(hasData ? L10n.tr("Aktualisierung fehlgeschlagen. Die zuletzt geladenen Details bleiben sichtbar.") : L10n.tr("Details konnten nicht geladen werden."), systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button(L10n.tr("Erneut versuchen"), action: retry).buttonStyle(.bordered).disabled(isLoading)
            }
            if !hasData && !isLoading && error == nil {
                Text(L10n.tr("Details wurden noch nicht geladen.")).font(.callout).foregroundStyle(.secondary)
                Button(L10n.tr("Details laden"), action: retry).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TestFlightRefreshButton: View {
    var isRefreshing: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isRefreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }.frame(width: 16, height: 16)
        }.buttonStyle(.borderless).disabled(isRefreshing)
            .accessibilityLabel(L10n.tr("Aktualisieren"))
    }
}

struct TestFlightTesterRow: View {
    var tester: ASCBetaTester

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let name = [tester.attributes.firstName, tester.attributes.lastName]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            Text(name.isEmpty ? (tester.attributes.email ?? tester.id) : name)
                .font(.callout.weight(.medium)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !name.isEmpty, let email = tester.attributes.email {
                Text(email).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.tr("Einladung: \(TestFlightPresentation.status(tester.attributes.inviteType)) · Status: \(TestFlightPresentation.status(tester.attributes.state))"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}
