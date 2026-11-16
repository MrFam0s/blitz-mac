// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// UI language only. Store localizations, terminal content and API identifiers
/// have their own language/identity and must never pass through this setting.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, de, en

    static let preferenceKey = "BlitzInterfaceLanguage"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L10n.tr("Automatisch (macOS)")
        case .de: return "Deutsch"
        case .en: return "English"
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .system
    }

    func resolved(preferredLanguages: [String]) -> String {
        guard self == .system else { return rawValue }
        // Follow macOS's ordered preferred languages, including regional tags.
        for language in preferredLanguages {
            let base = language.replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").first?.lowercased()
            if base == "de" || base == "en" { return base! }
        }
        return "en"
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        // App-domain preference, never NSGlobalDomain. Native macOS menus and
        // panels read this on the next launch, together with our UI catalog.
        if self == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([rawValue], forKey: "AppleLanguages") }
    }
}

enum L10n {
    /// Immutable for a running app so a language change cannot recreate a
    /// terminal session or mix old errors with newly translated controls.
    static let startupLanguage = AppLanguage.stored().resolved(preferredLanguages: Locale.preferredLanguages)
    @TaskLocal static var overrideLanguage: String?
    static var language: String { overrideLanguage ?? startupLanguage }
    static var locale: Locale { Locale(identifier: language) }
    static let tables = ["Interface", "Release", "Features", "Runtime"]

    struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let key: String
        let arguments: [String]

        init(stringLiteral value: String) { key = value; arguments = [] }
        init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }

        struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []
            init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity)
                arguments.reserveCapacity(interpolationCount)
            }
            mutating func appendLiteral(_ literal: String) { key += literal }
            mutating func appendInterpolation<T>(_ value: T) {
                key += "{\(arguments.count)}"
                arguments.append(String(describing: value))
            }
            mutating func appendInterpolation<T: CVarArg>(_ value: T, specifier: String) {
                appendInterpolation(String(format: specifier, locale: L10n.locale, value))
            }
        }
    }

    static func tr(_ message: Message) -> String {
        render(template: translation(message.key, language: language), arguments: message.arguments)
    }

    static func translation(_ key: String, language: String) -> String {
        guard let bundle = bundles[language] else { return key }
        for table in tables {
            let translated = bundle.localizedString(forKey: key, value: "__BLITZ_MISSING__", table: table)
            if translated != "__BLITZ_MISSING__" { return translated }
        }
        return key
    }

    private static let bundles: [String: Bundle] = {
        Dictionary(uniqueKeysWithValues: ["de", "en"].compactMap { language in
            guard let path = Bundle.appResources.path(forResource: language, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (language, bundle)
        })
    }()

    /// Substitute only tokens in the template, never tokens inside user data.
    /// This also avoids treating a percent sign in a name as a format directive.
    static func render(template: String, arguments: [String]) -> String {
        let expression = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        let matches = expression.matches(in: template, range: NSRange(template.startIndex..., in: template))
        var result = template
        for match in matches.reversed() {
            guard let numberRange = Range(match.range(at: 1), in: template),
                  let index = Int(template[numberRange]), arguments.indices.contains(index),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: arguments[index])
        }
        return result
    }
}
