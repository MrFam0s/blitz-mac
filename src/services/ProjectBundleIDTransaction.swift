import Foundation

/// Keeps a selected Xcode target and its local metadata in step. Call this
/// synchronously in the same actor turn that captures the original project.
enum ProjectBundleIDTransaction {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func update(projectPath: String, bundleID: String, scheme: String?, configuration: String?,
                       persistMetadata: () throws -> Void) throws {
        let editor = XcodeProjectIdentityEditor()
        let selection = try editor.select(projectPath: projectPath, scheme: scheme, configuration: configuration)
        let file = selection.projectURL.appendingPathComponent("project.pbxproj")
        let original = try Data(contentsOf: file)
        let written = try editor.update(projectPath: projectPath, bundleID: bundleID, scheme: scheme, configuration: configuration, expectedOriginal: original)
        do {
            try persistMetadata()
        } catch {
            let metadataError = error
            // Do not overwrite a concurrent Xcode save while undoing our edit.
            guard (try? Data(contentsOf: file)) == written else {
                throw Failure(message: "Project metadata could not be saved and the Xcode project changed meanwhile. Check the bundle ID in Xcode and Blitz Neo before building. \(metadataError.localizedDescription)")
            }
            do { try original.write(to: file, options: .atomic) }
            catch {
                throw Failure(message: "Project metadata could not be saved and the Xcode change could not be reverted. Check the bundle ID in Xcode and Blitz Neo before building. \(error.localizedDescription)")
            }
            throw metadataError
        }
    }
}
