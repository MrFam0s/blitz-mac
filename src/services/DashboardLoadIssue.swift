import Foundation

enum DashboardLoadIssue: Equatable {
    case offline, authentication, permissions, agreement, rateLimited, unavailable, missingCredentials
    case partialStatuses(Int)

    var title: String {
        switch self {
        case .offline: L10n.tr("Keine Verbindung")
        case .authentication, .missingCredentials: L10n.tr("App-Store-Connect-Zugang erforderlich")
        case .permissions: L10n.tr("Zugriff auf App Store Connect verweigert")
        case .agreement: L10n.tr("Apple-Vereinbarung prüfen")
        case .rateLimited: L10n.tr("App Store Connect ist ausgelastet")
        case .unavailable: L10n.tr("Apps konnten nicht aktualisiert werden")
        case .partialStatuses: L10n.tr("Einige App-Status konnten nicht aktualisiert werden")
        }
    }

    var message: String {
        switch self {
        case .offline: L10n.tr("Prüfe deine Internetverbindung und versuche es erneut.")
        case .authentication, .missingCredentials: L10n.tr("Prüfe deinen App-Store-Connect-API-Schlüssel in den Einstellungen und versuche es erneut.")
        case .permissions: L10n.tr("Prüfe die Berechtigungen deines API-Schlüssels in App Store Connect.")
        case .agreement: L10n.tr("Der Accountinhaber muss die aktuelle Vereinbarung bei Apple Developer prüfen.")
        case .rateLimited: L10n.tr("Warte einen Moment und versuche es erneut.")
        case .unavailable: L10n.tr("App Store Connect oder der lokale Hilfsdienst ist nicht erreichbar. Versuche es erneut.")
        case .partialStatuses(let count): L10n.tr("Für \(count) Apps fehlt der aktuelle Status. Vorhandene ältere Daten bleiben sichtbar; die Gesamtzahlen können veraltet oder unvollständig sein.")
        }
    }

    var needsSettings: Bool { self == .authentication || self == .missingCredentials || self == .permissions }

    static func from(_ error: Error) -> Self {
        if let error = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .timedOut, .dnsLookupFailed].contains(error.code) {
            return .offline
        }
        if let error = error as? ASCError {
            if error.isProgramLicenseAgreementRequired { return .agreement }
            if case .httpError(let code, _) = error {
                switch code {
                case 401: return .authentication
                case 403: return .permissions
                case 429: return .rateLimited
                default: break
                }
            }
        }
        // Do not expose raw HTTP/helper bodies, which may contain account data.
        return .unavailable
    }
}

protocol DashboardFetching {
    func fetchAllApps(appStoreStateFilter: String?) async throws -> [ASCApp]
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion]
    func fetchStoreAvailability(appId: String) async throws -> ASCStoreAvailability
    func fetchAppStoreIconURL(app: ASCApp, dimension: Int) async throws -> URL?
}

extension AppStoreConnectService: DashboardFetching {}
