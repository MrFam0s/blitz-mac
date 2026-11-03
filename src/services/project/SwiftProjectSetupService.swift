import CryptoKit
import Foundation

/// Scaffolds a new Swift/SwiftUI project from the bundled template.
/// Mirrors the logic in blitz-cn's create-swift-project.ts.
struct SwiftProjectSetupService {

    /// Create an ASCII technical name from the original name, preserving inner capitals.
    /// The public display name is stored separately and is never reconstructed from the folder slug.
    static func toSwiftAppName(_ projectName: String) -> String {
        let transliterated = projectName.applyingTransform(.toLatin, reverse: false) ?? projectName
        let ascii = transliterated.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let parts = ascii.components(separatedBy: allowed.inverted)
        let camel = parts
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()

        // Numeric names keep their digits. A rare untransliteratable name gets
        // a stable suffix rather than sharing the identifier "App" with others.
        guard let first = camel.first else {
            guard !projectName.isEmpty else { return "App" }
            let suffix = SHA256.hash(data: Data(projectName.utf8)).prefix(6)
                .map { String(format: "%02x", $0) }.joined()
            return "App" + suffix
        }
        return first.isLetter ? camel : "App" + camel
    }

    /// Derive a bundle ID: "MyCoolApp" → "dev.blitz.MyCoolApp".
    static func toBundleId(_ appName: String) -> String {
        let safe = appName.filter { $0.isLetter || $0.isNumber }
        return "dev.blitz.\(safe.isEmpty ? "App" : safe)"
    }

    /// Set up a new Swift project from the bundled template.
    /// Calls `onStep` on the main actor as each phase begins.
    static func setup(
        projectId: String,
        projectName: String,
        projectPath: String,
        onStep: @MainActor (ProjectSetupService.SetupStep) -> Void
    ) async throws {
        let appName = toSwiftAppName(projectName)
        let bundleId = toBundleId(appName)
        let spec = ProjectTemplateSpec(
            templateName: "swift-hello-template",
            missingTemplateMessage: "Bundled Swift template not found",
            replacements: [
                "__APP_NAME__": appName,
                "__BUNDLE_ID__": bundleId
            ],
            cleanupPaths: [],
            logPrefix: "swift-setup",
            propertyListFields: ["\(appName)/Info.plist": ["CFBundleDisplayName": projectName]]
        )
        try await ProjectTemplateScaffolder.scaffold(
            spec: spec,
            projectPath: projectPath,
            onStep: onStep
        )
    }
}
