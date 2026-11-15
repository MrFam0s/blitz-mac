import SwiftUI

enum TestFlightPresentation {
    static func status(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Nicht verfügbar" }
        switch value {
        case "PROCESSING": return "Wird verarbeitet"
        case "FAILED": return "Fehlgeschlagen"
        case "INVALID": return "Ungültig"
        case "VALID": return "Gültig"
        case "EXPIRED": return "Abgelaufen"
        case "MISSING_EXPORT_COMPLIANCE": return "Exportangaben fehlen"
        case "IN_EXPORT_COMPLIANCE_REVIEW": return "Exportangaben werden geprüft"
        case "WAITING_FOR_EXPORT_COMPLIANCE": return "Wartet auf Exportprüfung"
        case "READY_FOR_BETA_SUBMISSION": return "Bereit zur Beta-Einreichung"
        case "WAITING_FOR_BETA_REVIEW": return "Wartet auf Beta-Prüfung"
        case "IN_BETA_REVIEW": return "In Beta-Prüfung"
        case "BETA_REJECTED": return "Betatest abgelehnt"
        case "BETA_APPROVED": return "Für Betatest freigegeben"
        case "READY_FOR_BETA_TESTING", "READY_FOR_TESTING": return "Bereit zum Testen"
        case "IN_BETA_TESTING": return "Im Betatest"
        case "NOT_INVITED": return "Nicht eingeladen"
        case "INVITED": return "Eingeladen"
        case "ACCEPTED": return "Angenommen"
        case "INSTALLED": return "Installiert"
        case "REVOKED": return "Widerrufen"
        case "EMAIL": return "E-Mail"
        case "PUBLIC_LINK": return "Öffentlicher Link"
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
        default: return "Plattform unbekannt"
        }
    }

    static func buildLabel(_ build: ASCBuild) -> String {
        let version = build.preReleaseVersion?.attributes.version ?? "Version unbekannt"
        return "\(version) (\(build.attributes.version)) · \(platform(build.preReleaseVersion?.attributes.platform))"
    }

    static func expiration(_ build: ASCBuild, now: Date = Date()) -> String {
        if build.attributes.expired == true { return "Abgelaufen" }
        if let raw = build.attributes.expirationDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: raw)
            formatter.formatOptions = [.withInternetDateTime]
            if let date = fractional ?? formatter.date(from: raw) {
                return date <= now ? "Abgelaufen" : "Nicht abgelaufen"
            }
        }
        return build.attributes.expired == false ? "Nicht abgelaufen" : "Nicht verfügbar"
    }

    static func groupType(_ group: ASCBetaGroup) -> String {
        switch group.attributes.isInternalGroup {
        case true: "Intern"
        case false: "Extern"
        default: "Typ unbekannt"
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
                    Text(hasData ? "Details werden aktualisiert …" : "Details werden geladen …")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error {
                Label(hasData ? "Aktualisierung fehlgeschlagen. Die zuletzt geladenen Details bleiben sichtbar." : "Details konnten nicht geladen werden.", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button("Erneut versuchen", action: retry).buttonStyle(.bordered).disabled(isLoading)
            }
            if !hasData && !isLoading && error == nil {
                Text("Details wurden noch nicht geladen.").font(.callout).foregroundStyle(.secondary)
                Button("Details laden", action: retry).buttonStyle(.bordered)
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
            .accessibilityLabel("Aktualisieren")
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
            Text("Einladung: \(TestFlightPresentation.status(tester.attributes.inviteType)) · Status: \(TestFlightPresentation.status(tester.attributes.state))")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}
