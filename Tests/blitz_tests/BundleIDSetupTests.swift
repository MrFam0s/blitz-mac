import Testing
@testable import Blitz

@MainActor
@Test func bundleIDSetupPreservesOriginalAppName() {
    // This is the same prefill and composition path used before registration.
    let name = BundleIDSetupView.sanitizeComponent("ClubBundle")
    #expect(BundleIDSetupView.bundleIdentifier(
        prefix: "org", organization: "amosystems", appName: name
    ) == "org.amosystems.ClubBundle")
}

@MainActor
@Test func bundleIDSetupPreservesEnteredComponentCase() {
    #expect(BundleIDSetupView.bundleIdentifier(
        prefix: "Org", organization: "AmoSystems", appName: "ClubBundle-Mac2"
    ) == "Org.AmoSystems.ClubBundle-Mac2")
}

@MainActor
@Test func bundleIDSetupDoesNotRenameExistingLowercaseIdentifiers() {
    #expect(BundleIDSetupView.bundleIdentifier(
        prefix: "org", organization: "amosystems", appName: "clubbundle"
    ) == "org.amosystems.clubbundle")
}

@MainActor
@Test func bundleIDSetupStillFiltersUnsupportedComponentCharacters() {
    #expect(BundleIDSetupView.bundleIdentifier(
        prefix: " org ", organization: "amo_systems", appName: "Club Bundle!"
    ) == "org.amosystems.ClubBundle")
    #expect(BundleIDSetupView.bundleIdentifier(
        prefix: "org", organization: "", appName: "ClubBundle"
    ) == "org....")
}
