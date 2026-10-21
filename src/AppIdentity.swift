// Added for the AmoSystems maintenance fork (2026).
import Foundation

enum AppIdentity {
    static let name = "Blitz Neo"
    static let bundleIdentifier = "org.amosystems.BlitzNeo"
    static let legacyBundleIdentifier = "com.blitz.macos"
    static let installedAppPath = "/Applications/Blitz Neo.app"

    /// The project store, settings JSON, MCP paths and Keychain service names
    /// deliberately remain stable. Only preferences scoped to the bundle ID move.
    /// Copy known UI preferences once; never import transient restart instructions,
    /// authentication material or overwrite choices already made in Blitz Neo.
    static func migratePreferences(
        defaults: UserDefaults = .standard,
        destinationDomain: String = bundleIdentifier,
        sourceDomain: String = legacyBundleIdentifier
    ) {
        guard destinationDomain != sourceDomain else { return }
        let marker = "blitzNeo.didMigrateLegacyPreferences"
        var destination = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        guard destination[marker] as? Bool != true else { return }
        let legacy = defaults.persistentDomain(forName: sourceDomain) ?? [:]
        for key in [
            "selectedAIAgent", "NSWindow Frame BlitzMainWindow", "NSWindow Frame main",
            "NSSplitView Subview Frames main, SidebarNavigationSplitView"
        ] {
            if destination[key] == nil, let value = legacy[key] {
                destination[key] = value
            }
        }
        destination[marker] = true
        defaults.setPersistentDomain(destination, forName: destinationDomain)
    }
}
