import Foundation

/// Scaffolds a new React Native / Blitz project from the bundled template.
/// Handles the full lifecycle: copy template → patch placeholders.
/// Dependency install, runtime setup, and builds are handled by the user's agent.
struct ProjectSetupService {

    enum SetupStep: String {
        case copying = "Copying template..."
        case ready = "Ready"
    }

    struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func packageName(for projectName: String) -> String {
        // A distinct safe package identifier; user-visible names remain unchanged.
        SwiftProjectSetupService.toSwiftAppName(projectName).lowercased()
    }

    /// Set up a new project from the bundled RN template.
    /// Calls `onStep` on the main actor as each phase begins.
    static func setup(
        projectId: String,
        projectName: String,
        projectPath: String,
        onStep: @MainActor (SetupStep) -> Void
    ) async throws {
        let spec = ProjectTemplateSpec(
            templateName: "rn-notes-template",
            missingTemplateMessage: "Bundled RN template not found",
            replacements: [:],
            cleanupPaths: [],
            logPrefix: "setup",
            jsonFields: [
                "package.json": ["name": packageName(for: projectName)],
                "app.json": ["name": SwiftProjectSetupService.toSwiftAppName(projectName), "displayName": projectName]
            ]
        )
        try await ProjectTemplateScaffolder.scaffold(
            spec: spec,
            projectPath: projectPath,
            onStep: onStep
        )
    }
}
