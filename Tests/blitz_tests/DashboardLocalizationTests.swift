import Foundation
import Testing
@testable import Blitz

@Test func dashboardPlatformCacheIsIndependentOfInterfaceLanguage() throws {
    let versions: [ASCAppStoreVersion] = try JSONDecoder().decode([ASCAppStoreVersion].self, from: Data("""
    [
      {"id":"ios","attributes":{"versionString":"1.0","platform":"IOS","appStoreState":"READY_FOR_SALE"}},
      {"id":"mac","attributes":{"versionString":"1.0","platform":"MAC_OS","appStoreState":"WAITING_FOR_REVIEW"}}
    ]
    """.utf8))
    let german = L10n.$overrideLanguage.withValue("de") {
        ASCDashboardProjectStatus(versions: versions, availability: .available)
    }
    let english = L10n.$overrideLanguage.withValue("en") {
        ASCDashboardProjectStatus(versions: versions, availability: .available)
    }
    #expect(german == english)
    #expect(german.platformSummaries == ["IOS": "LIVE_ON_STORE", "MAC_OS": "IN_REVIEW"])
    let restored = try JSONDecoder().decode(ASCDashboardProjectStatus.self, from: JSONEncoder().encode(german))
    L10n.$overrideLanguage.withValue("de") {
        #expect(restored.localizedPlatformSummaries?["MAC_OS"] == "In Prüfung")
    }
    L10n.$overrideLanguage.withValue("en") {
        #expect(restored.localizedPlatformSummaries?["MAC_OS"] == "In review")
    }
    #expect(restored == german)
}

@Test func dashboardTranslatesLegacyOwnedLabelsWithoutChangingUnknownValues() throws {
    for legacy in ["In Prüfung", "In Review", "In review"] {
        var status = ASCDashboardProjectStatus.empty
        status.platformSummaries = ["IOS": legacy, "FUTURE_PLATFORM": "Custom {0} status"]
        let restored = try JSONDecoder().decode(ASCDashboardProjectStatus.self, from: JSONEncoder().encode(status))
        L10n.$overrideLanguage.withValue("de") {
            #expect(restored.localizedPlatformSummaries?["IOS"] == "In Prüfung")
            #expect(restored.localizedPlatformSummaries?["FUTURE_PLATFORM"] == "Custom {0} status")
        }
        L10n.$overrideLanguage.withValue("en") {
            #expect(restored.localizedPlatformSummaries?["IOS"] == "In review")
        }
        #expect(restored.platformSummaries?["IOS"] == legacy)
    }
}
