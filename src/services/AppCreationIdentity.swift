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
            throw InvalidIdentity(message: "Enter the public app name (2–30 characters, without surrounding spaces).")
        }
        guard Self.validBundleID(bundleId) else {
            throw InvalidIdentity(message: "The bundle ID must contain only A–Z, a–z, 0–9, hyphens and nonempty dot-separated components. Its spelling will not be changed automatically.")
        }
        guard Self.validSKU(sku) else {
            throw InvalidIdentity(message: "Review the SKU: use letters, numbers, hyphens, periods or underscores, starting with a letter or number. Spaces are not allowed.")
        }
        guard primaryLocale.range(of: #"\A[a-z]{2,3}(-[A-Za-z0-9]{2,8})*\z"#, options: .regularExpression) != nil else {
            throw InvalidIdentity(message: "Enter the primary language code, for example de-DE or en-US.")
        }
    }

    func verify(app: ASCApp, versions: [ASCAppStoreVersion]) throws {
        try validate()
        guard app.bundleId == bundleId else { throw InvalidIdentity(message: "Apple returned bundle ID ‘\(app.bundleId)’ instead of ‘\(bundleId)’. Confirm the actual registered identifier before continuing.") }
        guard app.name == appName else { throw InvalidIdentity(message: "Apple returned app name ‘\(app.name)’ instead of ‘\(appName)’. The app has not been confirmed.") }
        guard app.attributes.sku == sku else { throw InvalidIdentity(message: "The SKU returned by Apple does not match the confirmed SKU ‘\(sku)’. The app has not been confirmed.") }
        guard app.primaryLocale == primaryLocale else { throw InvalidIdentity(message: "The primary language returned by Apple does not match ‘\(primaryLocale)’.") }
        let expectedPlatform = platform == .macOS ? "MAC_OS" : "IOS"
        guard versions.contains(where: { $0.attributes.platform == expectedPlatform }) else {
            throw InvalidIdentity(message: "Apple has not returned a version for the confirmed \(platform.rawValue) platform.")
        }
    }
}
