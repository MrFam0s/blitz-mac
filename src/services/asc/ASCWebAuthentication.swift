import Foundation

enum ASCWebAuthenticationError: Error, LocalizedError {
    case notAuthenticated
    case invalidResponse
    case transport
    case accountChanged

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Apple hat die Anmeldung noch nicht bestätigt. Bitte schließe die Anmeldung in diesem Fenster ab."
        case .invalidResponse:
            return "Apple hat keine gültige App-Store-Connect-Sitzung zurückgegeben. Die Anmeldung wurde noch nicht übernommen."
        case .transport:
            return "Die Apple-Anmeldung konnte nicht geprüft werden. Bitte prüfe die Verbindung und versuche es erneut."
        case .accountChanged:
            return "Das Apple-Konto hat sich während der Prüfung geändert. Bitte melde dich erneut an."
        }
    }
}

/// A browser cookie is only a candidate. Confirm it against Apple's session
/// endpoint before storing it or reporting successful MCP authentication.
enum ASCWebAuthentication {
    static let sessionURL = URL(string: "https://appstoreconnect.apple.com/olympus/v1/session")!

    static func isAppStoreConnectURL(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https"
            && url?.host?.lowercased() == "appstoreconnect.apple.com"
            && (url?.port == nil || url?.port == 443)
    }

    static func authenticatedEmail(statusCode: Int, data: Data) throws -> String {
        guard statusCode == 200 else { throw ASCWebAuthenticationError.notAuthenticated }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["user"] as? [String: Any],
              let rawEmail = user["emailAddress"] as? String else {
            throw ASCWebAuthenticationError.invalidResponse
        }
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { throw ASCWebAuthenticationError.invalidResponse }
        return email
    }

    static func cookieHeader(
        from cookies: [IrisSession.IrisCookie],
        for url: URL = sessionURL,
        now: Date = Date()
    ) -> String {
        guard isAppStoreConnectURL(url), let host = url.host else { return "" }
        let requestPath = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let path = cookie.path.isEmpty ? "/" : cookie.path
            let domainMatches = !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
            let pathMatches = requestPath == path
                || (requestPath.hasPrefix(path) && (path.hasSuffix("/") || requestPath.dropFirst(path.count).hasPrefix("/")))
            return domainMatches && pathMatches && (cookie.expires.map { $0 > now } ?? true)
                && !cookie.name.isEmpty && !cookie.name.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "=" })
                && !cookie.value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || $0 == ";" })
        }
        .sorted { $0.path.count > $1.path.count }
        .map { cookie in
            let value = cookie.value
            // Foundation, like Go's http.Cookie, needs quotes around Apple's
            // DES cookie values containing spaces or commas.
            let encoded = value.contains(" ") || value.contains(",")
                ? "\"\(value.replacingOccurrences(of: "\"", with: ""))\"" : value
            return "\(cookie.name)=\(encoded)"
        }
        .joined(separator: "; ")
    }


}

/// Invalidating a browser navigation also invalidates all of its async checks.
struct ASCWebCaptureGate {
    private var pending: UUID?
    private var isActive = true

    mutating func begin() -> UUID? {
        guard isActive, pending == nil else { return nil }
        let token = UUID()
        pending = token
        return token
    }

    func accepts(_ token: UUID) -> Bool { isActive && pending == token }
    mutating func finish(_ token: UUID) { if accepts(token) { pending = nil } }
    mutating func invalidate() { pending = nil }
    mutating func cancel() { isActive = false; pending = nil }
}
