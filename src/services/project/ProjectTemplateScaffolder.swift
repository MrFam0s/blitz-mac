import Darwin
import Foundation

struct ProjectTemplateSpec {
    let templateName: String
    let missingTemplateMessage: String
    let replacements: [String: String]
    let cleanupPaths: [String]
    let logPrefix: String
    var jsonFields: [String: [String: String]] = [:]
    var propertyListFields: [String: [String: String]] = [:]
}

/// Shared template copier used by React Native, Swift, and macOS Swift setup services.
enum ProjectTemplateScaffolder {
    static func scaffold(
        spec: ProjectTemplateSpec,
        projectPath: String,
        onStep: @MainActor (ProjectSetupService.SetupStep) -> Void
    ) async throws {
        await onStep(.copying)
        print("[\(spec.logPrefix)] Copying bundled template")

        guard let templateURL = Bundle.appResources.url(
            forResource: spec.templateName,
            withExtension: nil,
            subdirectory: "templates"
        ) else {
            throw ProjectSetupService.SetupError(message: spec.missingTemplateMessage)
        }

        try scaffold(spec: spec, templateURL: templateURL, projectDirectory: URL(fileURLWithPath: projectPath))

        await onStep(.ready)
        print("[\(spec.logPrefix)] Project setup complete")
    }

    /// Prepare all template files first; only a reserved project may receive them.
    /// Publishing never replaces a destination entry, even if another process creates it.
    static func scaffold(spec: ProjectTemplateSpec, templateURL: URL, projectDirectory: URL) throws {
        let fm = FileManager.default
        let token = try ProjectCreationReservation.validate(projectDirectory)
        let staging = projectDirectory.deletingLastPathComponent()
            .appendingPathComponent(".blitz-stage-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        try copyTemplateDir(src: templateURL, dest: staging, replacements: spec.replacements)
        for (path, values) in spec.jsonFields {
            let file = try containedFile(path, in: staging)
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
            for (key, value) in values { object[key] = value }
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: file)
        }
        for (path, values) in spec.propertyListFields {
            let file = try containedFile(path, in: staging)
            var object: [String: Any] = [:]
            if fm.fileExists(atPath: file.path) {
                object = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] ?? [:]
            }
            for (key, value) in values { object[key] = value }
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: file)
        }
        for path in spec.cleanupPaths {
            let item = staging.appendingPathComponent(path).standardizedFileURL
            guard item.path.hasPrefix(staging.path + "/") else {
                throw ProjectSetupService.SetupError(message: "Invalid template cleanup path.")
            }
            if fm.fileExists(atPath: item.path) { try fm.removeItem(at: item) }
        }
        let entries = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard !entries.contains(where: { $0.lastPathComponent == ".blitz" }) else {
            throw ProjectSetupService.SetupError(message: "Template may not replace project metadata.")
        }
        guard try ProjectCreationReservation.validate(projectDirectory) == token else {
            throw ProjectSetupService.SetupError(message: "The project folder changed during setup.")
        }
        for entry in entries {
            let destination = projectDirectory.appendingPathComponent(entry.lastPathComponent)
            if (try? fm.attributesOfItem(atPath: destination.path)) != nil {
                throw ProjectSetupService.SetupError(message: "Project setup would replace existing files. The existing files were preserved.")
            }
        }
        for entry in entries {
            guard try ProjectCreationReservation.validate(projectDirectory) == token else {
                throw ProjectSetupService.SetupError(message: "The project folder changed during setup.")
            }
            let destination = projectDirectory.appendingPathComponent(entry.lastPathComponent)
            let result = entry.path.withCString { source in
                destination.path.withCString { target in Darwin.renamex_np(source, target, UInt32(RENAME_EXCL)) }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        try fm.removeItem(at: projectDirectory.appendingPathComponent(".blitz/" + ProjectCreationReservation.markerName))
    }

    private static func containedFile(_ path: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(directory.path + "/") else {
            throw ProjectSetupService.SetupError(message: "Invalid template output path.")
        }
        return file
    }

    private static func copyTemplateDir(src: URL, dest: URL, replacements: [String: String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let entries = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey])
        for entry in entries {
            let resolvedName = applyReplacements(to: entry.lastPathComponent, replacements: replacements)
            let destPath = dest.appendingPathComponent(resolvedName)

            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)

            if isDir.boolValue {
                try copyTemplateDir(src: entry, dest: destPath, replacements: replacements)
            } else {
                var content = try String(contentsOf: entry, encoding: .utf8)
                content = applyReplacements(to: content, replacements: replacements)
                try content.write(to: destPath, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func applyReplacements(to value: String, replacements: [String: String]) -> String {
        replacements.reduce(value) { partialResult, replacement in
            partialResult.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }
}
