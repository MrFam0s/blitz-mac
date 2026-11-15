import Testing
@testable import Blitz

@Test func germanPresentationPreservesUserContentAndUnknownValues() {
    // User-authored Store text can happen to match a translated system value.
    for field in ["App Name", "Description", "Keywords", "Copyright", "Support URL"] {
        #expect(BlitzDisplayText.readinessValue("Configured", field: field) == "Configured")
        #expect(BlitzDisplayText.readinessValue("Free", field: field) == "Free")
    }
    #expect(BlitzDisplayText.status("NEW_APPLE_STATE") == "NEW_APPLE_STATE")
    #expect(TestFlightPresentation.status("NEW_BETA_STATE") == "NEW_BETA_STATE")
    #expect(BlitzDisplayText.fieldLabel("Future field") == "Future field")
    #expect(BlitzDisplayText.category("NEW_CATEGORY") == "NEW_CATEGORY")
}

@Test func germanPresentationKeepsNavigationAndReadinessKeysStable() {
    #expect(AppTab.appInformation.rawValue == "appInformation")
    #expect(AppTab.groups.rawValue == "groups")
    #expect(AppSubTab.overview.rawValue == "overview")
    #expect(BlitzDisplayText.fieldLabel("What's New (en-US)") == "Neuigkeiten (en-US)")
    #expect(BlitzDisplayText.readinessValue("Configured", field: "App Icon") == "Eingerichtet")
    #expect(BlitzDisplayText.readinessValue("3 screenshot(s)", field: "Mac Screenshots") == "3 Screenshots")
    #expect(BlitzDisplayText.readinessValue("https://example.com/Free", field: "Support URL") == "https://example.com/Free")
}
