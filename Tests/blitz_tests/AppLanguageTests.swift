import Foundation
import Testing
@testable import Blitz

@Test func interfaceLanguageFollowsMacOSPreferenceOrderAndRegionalVariants() {
    #expect(AppLanguage.system.resolved(preferredLanguages: ["de-DE", "en-US"]) == "de")
    #expect(AppLanguage.system.resolved(preferredLanguages: ["en_GB", "de"]) == "en")
    #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "de-CH"]) == "de")
    #expect(AppLanguage.system.resolved(preferredLanguages: ["ja"]) == "en")
    #expect(AppLanguage.system.resolved(preferredLanguages: []) == "en")
    #expect(AppLanguage.en.resolved(preferredLanguages: ["de"]) == "en")
    #expect(AppLanguage.de.resolved(preferredLanguages: ["en"]) == "de")
}

@Test func interfaceLanguagePersistenceOnlyChangesItsOwnPreferenceDomain() throws {
    let suite = "BlitzLanguageTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let originalStandardLanguages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]
    defaults.set("de-DE", forKey: "StoreLocaleFixture")
    #expect(AppLanguage.stored(in: defaults) == .system)
    AppLanguage.en.save(in: defaults)
    #expect(AppLanguage.stored(in: defaults) == .en)
    #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])
    AppLanguage.de.save(in: defaults)
    #expect(defaults.stringArray(forKey: "AppleLanguages") == ["de"])
    AppLanguage.system.save(in: defaults)
    #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
    #expect(defaults.string(forKey: "StoreLocaleFixture") == "de-DE")
    #expect(UserDefaults.standard.array(forKey: "AppleLanguages") as? [String] == originalStandardLanguages)
    defaults.set("obsolete", forKey: AppLanguage.preferenceKey)
    #expect(AppLanguage.stored(in: defaults) == .system)
}

@Test func interfaceCatalogsContainMatchingMessagesAndInterpolationTokens() throws {
    let tokenPattern = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
    func tokens(_ text: String) -> [String] {
        tokenPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range, in: text)!]) }.sorted()
    }
    var seen: [String: String] = [:]
    for table in L10n.tables {
        func read(_ language: String) throws -> [String: String] {
            let path = try #require(Bundle.appResources.path(forResource: table, ofType: "strings", inDirectory: "\(language).lproj"))
            return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: String])
        }
        let german = try read("de"), english = try read("en")
        #expect(!german.isEmpty)
        #expect(Set(german.keys) == Set(english.keys))
        for (key, translation) in english {
            #expect(!translation.isEmpty)
            #expect(tokens(key) == tokens(translation), "Interpolation mismatch: \(key)")
            #expect(tokens(key) == tokens(german[key] ?? ""))
            if let previous = seen[key] { #expect(previous == translation, "Conflicting translation: \(key)") }
            seen[key] = translation
        }
    }
}

@Test(arguments: ["de", "en"])
func interfaceLanguageLocalizesPresentationWithoutChangingStoreContent(_ language: String) {
    L10n.$overrideLanguage.withValue(language) {
        #expect(AppTab.appInformation.label == (language == "de" ? "App-Informationen" : "App Information"))
        #expect(AppTab.settings.label == (language == "de" ? "Einstellungen" : "Settings"))
        #expect(AppTab.appInformation.rawValue == "appInformation")
        #expect(BlitzDisplayText.fieldLabel("What's New (de-DE)") == (language == "de" ? "Neuigkeiten (de-DE)" : "What’s New (de-DE)"))
        for field in ["App Name", "Description", "Keywords", "Copyright"] {
            #expect(BlitzDisplayText.readinessValue("Free", field: field) == "Free")
            #expect(BlitzDisplayText.readinessValue("Neuigkeiten", field: field) == "Neuigkeiten")
        }
        #expect(BlitzDisplayText.status("FUTURE_APPLE_STATE") == "FUTURE_APPLE_STATE")
        #expect(TestFlightPresentation.status("FUTURE_BETA_STATE") == "FUTURE_BETA_STATE")
        let name = "ContactHelper {1} % 🧑‍💻"
        #expect(L10n.tr("\(name) öffnen") == (language == "de" ? "\(name) öffnen" : "Open \(name)"))
    }
}

@Test func interfaceInterpolationSupportsReorderingWithoutReinterpretingUserData() {
    #expect(L10n.render(template: "{1} / {0} / {1}", arguments: ["{1}%", "🧑‍💻"]) == "🧑‍💻 / {1}% / 🧑‍💻")
    #expect(L10n.render(template: "Missing {4}", arguments: ["x"]) == "Missing {4}")
    L10n.$overrideLanguage.withValue("en") {
        #expect(L10n.tr("Version \("1.2") · Build \(42)") == "Version 1.2 · Build 42")
    }
}
