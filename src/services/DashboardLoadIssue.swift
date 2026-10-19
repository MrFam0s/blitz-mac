import Foundation

enum DashboardLoadIssue: Equatable {
    case offline, authentication, permissions, agreement, rateLimited, unavailable, missingCredentials
    case partialStatuses(Int)

    var title: String {
        switch self {
        case .offline: "Connection unavailable"
        case .authentication, .missingCredentials: "App Store Connect sign-in required"
        case .permissions: "App Store Connect access denied"
        case .agreement: "Apple agreement needs attention"
        case .rateLimited: "App Store Connect is busy"
        case .unavailable: "Couldn’t refresh apps"
        case .partialStatuses: "Some app statuses couldn’t be refreshed"
        }
    }

    var message: String {
        switch self {
        case .offline: "Check your internet connection and try again."
        case .authentication, .missingCredentials: "Check your App Store Connect API key in Settings, then retry."
        case .permissions: "Check your API key permissions in App Store Connect."
        case .agreement: "Your Account Holder needs to review the latest agreement in Apple Developer."
        case .rateLimited: "Wait a moment before trying again."
        case .unavailable: "App Store Connect or its local helper could not be reached. Try again."
        case .partialStatuses(let count): "Status unavailable for \(count) app(s). Previous statuses are retained where available; totals may be outdated or incomplete."
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
    func fetchAppStoreIconURL(app: ASCApp, dimension: Int) async throws -> URL?
}

extension AppStoreConnectService: DashboardFetching {}
