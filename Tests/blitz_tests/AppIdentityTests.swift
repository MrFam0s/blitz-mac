// Added for the AmoSystems maintenance fork (2026).
import Foundation
import Testing
@testable import Blitz

@Test func legacyPreferencesMigrateWithoutOverwritingNeoChoicesOrCopyingRestartState() {
    let source = "test.blitz.legacy.\(UUID().uuidString)"
    let target = "test.blitz.neo.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: target)!
    defer {
        defaults.removePersistentDomain(forName: source)
        defaults.removePersistentDomain(forName: target)
    }
    defaults.setPersistentDomain([
        "selectedAIAgent": "codex",
        "NSWindow Frame BlitzMainWindow": "100 100 1230 925 0 0 1728 1117 ",
        "blitz.pendingRelaunch.appPath": "/Applications/Blitz.app",
        "unrelatedPrivateValue": "not migrated"
    ], forName: source)
    defaults.setPersistentDomain(["selectedAIAgent": "claudeCode"], forName: target)

    AppIdentity.migratePreferences(defaults: defaults, destinationDomain: target, sourceDomain: source)
    let migrated = defaults.persistentDomain(forName: target)!
    #expect(migrated["selectedAIAgent"] as? String == "claudeCode")
    #expect(migrated["NSWindow Frame BlitzMainWindow"] as? String == "100 100 1230 925 0 0 1728 1117 ")
    #expect(migrated["blitz.pendingRelaunch.appPath"] == nil)
    #expect(migrated["unrelatedPrivateValue"] == nil)
    #expect(defaults.persistentDomain(forName: source)?["selectedAIAgent"] as? String == "codex")

    defaults.removeObject(forKey: "NSWindow Frame BlitzMainWindow")
    AppIdentity.migratePreferences(defaults: defaults, destinationDomain: target, sourceDomain: source)
    #expect(defaults.persistentDomain(forName: target)?["NSWindow Frame BlitzMainWindow"] == nil)
}

@Test func legacyAgentSelectionSurvivesFirstNeoLaunch() {
    let source = "test.blitz.legacy.\(UUID().uuidString)"
    let target = "test.blitz.neo.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: target)!
    defer {
        defaults.removePersistentDomain(forName: source)
        defaults.removePersistentDomain(forName: target)
    }
    defaults.setPersistentDomain(["selectedAIAgent": "codex"], forName: source)
    AppIdentity.migratePreferences(defaults: defaults, destinationDomain: target, sourceDomain: source)
    #expect(defaults.string(forKey: "selectedAIAgent") == "codex")
}
