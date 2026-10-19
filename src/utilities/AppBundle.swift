import Foundation

extension Bundle {
    /// Custom resource bundle accessor for .app bundles.
    ///
    /// SPM's auto-generated `Bundle.module` looks at `Bundle.main.bundleURL` (the .app root),
    /// but macOS code signing requires resources inside `Contents/Resources/`.
    /// This accessor checks the correct path so it works in both:
    ///   - .app bundles (Contents/Resources/Blitz_Blitz.bundle)
    ///   - SPM development (next to executable)
    static let appResources: Bundle = {
        let bundleName = "Blitz_Blitz"

        // 1. Standard macOS .app location: Contents/Resources/
        if let resourceURL = Bundle.main.resourceURL {
            let path = resourceURL.appendingPathComponent("\(bundleName).bundle").path
            if let bundle = Bundle(path: path) {
                return bundle
            }
        }

        // 2. SPM default: next to the executable (bundleURL for .app = .app root)
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("\(bundleName).bundle").path
        if let bundle = Bundle(path: mainPath) {
            return bundle
        }

        // 3. Development: next to the built binary
        #if DEBUG
        let execPath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("\(bundleName).bundle").path
        if let execPath, let bundle = Bundle(path: execPath) {
            return bundle
        }
        // swift test runs inside SwiftPM's test helper, away from our executable.
        return Bundle.module
        #else
        fatalError("Could not find resource bundle \(bundleName)")
        #endif
    }()
}
