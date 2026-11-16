import Foundation

/// Confirmed public identity, shared by manual creation, agent creation and verification.
struct AppCreationIdentity: Codable, Equatable {
    var appName: String
    var bundleId: String
    var sku: String
    var platform: ProjectPlatform
    var primaryLocale: String

    struct InvalidIdentity: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func validBundleID(_ value: String) -> Bool {
        value.range(of: #"\A[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+\z"#, options: .regularExpression) != nil
    }

    static func validSKU(_ value: String) -> Bool {
        value.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil
    }

    func validate() throws {
        guard appName == appName.trimmingCharacters(in: .whitespacesAndNewlines), (2...30).contains(appName.unicodeScalars.count),
              !appName.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw InvalidIdentity(message: L10n.tr("Gib den öffentlichen App-Namen ein (2–30 Zeichen, ohne Leerzeichen am Anfang oder Ende)."))
        }
        guard Self.validBundleID(bundleId) else {
            throw InvalidIdentity(message: L10n.tr("Die Bundle-ID darf nur A–Z, a–z, 0–9 und Bindestriche enthalten. Ihre durch Punkte getrennten Bestandteile dürfen nicht leer sein. Die Schreibweise wird nicht automatisch geändert."))
        }
        guard Self.validSKU(sku) else {
            throw InvalidIdentity(message: L10n.tr("Prüfe die SKU: Erlaubt sind Buchstaben, Zahlen, Bindestriche, Punkte und Unterstriche. Sie muss mit einem Buchstaben oder einer Zahl beginnen. Leerzeichen sind nicht erlaubt."))
        }
        guard primaryLocale.range(of: #"\A[a-z]{2,3}(-[A-Za-z0-9]{2,8})*\z"#, options: .regularExpression) != nil else {
            throw InvalidIdentity(message: L10n.tr("Gib den Code der Hauptsprache ein, zum Beispiel de-DE oder en-US."))
        }
    }

    /// A new-record operation belongs to one selected, unbound local target.
    /// Before registration the confirmed form may replace a placeholder bundle;
    /// once registered, that exact spelling must remain unchanged.
    func validateProjectTarget(_ metadata: BlitzProjectMetadata, targetId: String?, registrationComplete: Bool) throws -> String {
        try metadata.validateReleaseTargetConfiguration()
        guard let target = metadata.selectedReleaseTarget,
              targetId == nil || target.id == targetId,
              target.platform == platform, target.storeBinding == nil,
              !registrationComplete || target.bundleIdentifier == bundleId else {
            throw InvalidIdentity(message: L10n.tr("Das bestätigte Veröffentlichungsziel hat sich geändert oder besitzt bereits eine Store-Zuordnung. Bitte die ursprüngliche Identität erneut prüfen."))
        }
        return target.id
    }

    func verify(app: ASCApp, versions: [ASCAppStoreVersion]) throws {
        try validate()
        guard app.bundleId == bundleId else { throw InvalidIdentity(message: L10n.tr("Apple hat die Bundle-ID „\(app.bundleId)“ statt „\(bundleId)“ zurückgegeben. Bestätige die tatsächlich registrierte Kennung, bevor du fortfährst.")) }
        guard app.name == appName else { throw InvalidIdentity(message: L10n.tr("Apple hat den App-Namen „\(app.name)“ statt „\(appName)“ zurückgegeben. Die App wurde nicht bestätigt.")) }
        guard app.attributes.sku == sku else { throw InvalidIdentity(message: L10n.tr("Die von Apple zurückgegebene SKU stimmt nicht mit der bestätigten SKU „\(sku)“ überein. Die App wurde nicht bestätigt.")) }
        guard app.primaryLocale == primaryLocale else { throw InvalidIdentity(message: L10n.tr("Die von Apple zurückgegebene Hauptsprache stimmt nicht mit „\(primaryLocale)“ überein.")) }
        let expectedPlatform = platform == .macOS ? "MAC_OS" : "IOS"
        guard versions.contains(where: { $0.attributes.platform == expectedPlatform }) else {
            throw InvalidIdentity(message: L10n.tr("Apple hat keine Version für die bestätigte Plattform \(platform.rawValue) zurückgegeben."))
        }
    }
}
