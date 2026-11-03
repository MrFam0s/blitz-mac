// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Darwin
import Foundation

/// Repository for `~/.blitz/projects` metadata and symlink registration.
struct ProjectRepository {
    let baseDirectory: URL
    private var metadataHydrator: ProjectMetadataHydrator { ProjectMetadataHydrator() }

    func listProjects() async -> [Project] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var projects: [Project] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let metadataFile = metadataURL(for: entry.lastPathComponent)
            guard let data = try? Data(contentsOf: metadataFile),
                  let decodedMetadata = try? decoder.decode(BlitzProjectMetadata.self, from: data) else {
                continue
            }

            let hydrated = hydratedMetadataIfNeeded(
                decodedMetadata,
                projectId: entry.lastPathComponent,
                projectDirectory: entry
            )

            projects.append(
                Project(
                    id: entry.lastPathComponent,
                    metadata: hydrated,
                    path: entry.path
                )
            )
        }

        return projects.sorted { ($0.metadata.lastOpenedAt ?? .distantPast) > ($1.metadata.lastOpenedAt ?? .distantPast) }
    }

    func readMetadata(projectId: String) -> BlitzProjectMetadata? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: metadataURL(for: projectId)),
              let metadata = try? decoder.decode(BlitzProjectMetadata.self, from: data) else {
            return nil
        }

        return hydratedMetadataIfNeeded(
            metadata,
            projectId: projectId,
            projectDirectory: baseDirectory.appendingPathComponent(projectId)
        )
    }

    /// Reserves the destination exclusively before the first metadata write.
    func createProject(metadata: BlitzProjectMetadata) throws -> String {
        let reserved = try ProjectCreationReservation.reserve(name: metadata.name, in: baseDirectory)
        try writeMetadataToDirectory(reserved.directory, metadata: metadata)
        return reserved.id
    }

    func readMetadataFromDirectory(_ directory: URL) throws -> BlitzProjectMetadata? {
        let file = directory.appendingPathComponent(".blitz/project.json")
        do {
            _ = try FileManager.default.attributesOfItem(atPath: file.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BlitzProjectMetadata.self, from: Data(contentsOf: file))
    }

    /// Re-import only changes choices visible in the import form, never the saved name or unrelated settings.
    func metadataForImport(directory: URL, type: ProjectType, platform: ProjectPlatform, selectedBundleID: String?) throws -> BlitzProjectMetadata {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectSetupService.SetupError(message: "Select an existing project folder to import.")
        }
        var metadata = try readMetadataFromDirectory(directory) ?? BlitzProjectMetadata(
            name: directory.lastPathComponent, type: type, platform: platform, createdAt: Date()
        )
        metadata.type = type
        metadata.platform = platform
        if let selected = selectedBundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            metadata.bundleIdentifier = selected
        }
        metadata.lastOpenedAt = Date()
        return metadataHydrator.hydrate(metadata, projectDirectory: directory).metadata
    }

    func writeMetadata(projectId: String, metadata: BlitzProjectMetadata) throws {
        try writeMetadataToDirectory(baseDirectory.appendingPathComponent(projectId), metadata: metadata)
    }

    func writeMetadataToDirectory(_ dir: URL, metadata: BlitzProjectMetadata) throws {
        let blitzDir = dir.appendingPathComponent(".blitz")
        try FileManager.default.createDirectory(at: blitzDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: blitzDir.appendingPathComponent("project.json"))
    }

    func deleteProject(projectId: String) throws {
        let projectDir = baseDirectory.appendingPathComponent(projectId)
        let path = projectDir.path
        var isSymlink = false
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            isSymlink = true
        }

        if isSymlink {
            unlink(path)
        } else {
            try FileManager.default.removeItem(at: projectDir)
        }
    }

    /// Validates `.blitz/project.json` exists, registers a symlink under
    /// `~/.blitz/projects/` if needed, and returns the project ID.
    func openProject(at url: URL) throws -> String {
        let metadataFile = url.appendingPathComponent(".blitz/project.json")
        guard FileManager.default.fileExists(atPath: metadataFile.path) else {
            throw ProjectOpenError.notABlitzProject
        }

        var folderName = url.lastPathComponent
        let existingDir = baseDirectory.appendingPathComponent(folderName)

        if FileManager.default.fileExists(atPath: existingDir.path) {
            let resolvedExisting = existingDir.resolvingSymlinksInPath().path
            let resolvedNew = url.resolvingSymlinksInPath().path
            if resolvedExisting == resolvedNew {
                updateLastOpened(projectId: folderName)
                return folderName
            }

            var counter = 2
            while FileManager.default.fileExists(
                atPath: baseDirectory.appendingPathComponent("\(folderName)-\(counter)").path
            ) {
                counter += 1
            }
            folderName = "\(folderName)-\(counter)"
        }

        let symlinkDir = baseDirectory.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: url)

        updateLastOpened(projectId: folderName)
        return folderName
    }

    func updateLastOpened(projectId: String) {
        guard var metadata = readMetadata(projectId: projectId) else { return }
        metadata.lastOpenedAt = Date()
        do {
            try writeMetadata(projectId: projectId, metadata: metadata)
        } catch {
            print("[ProjectRepository] Failed to update lastOpenedAt for \(projectId): \(error)")
        }
    }

    func clearRecentProjects() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }

        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let projectId = entry.lastPathComponent
            guard var metadata = readMetadata(projectId: projectId) else { continue }
            metadata.lastOpenedAt = nil
            try? writeMetadata(projectId: projectId, metadata: metadata)
        }
    }

    private func metadataURL(for projectId: String) -> URL {
        baseDirectory
            .appendingPathComponent(projectId)
            .appendingPathComponent(".blitz/project.json")
    }

    private func hydratedMetadataIfNeeded(
        _ metadata: BlitzProjectMetadata,
        projectId: String,
        projectDirectory: URL
    ) -> BlitzProjectMetadata {
        let result = metadataHydrator.hydrate(metadata, projectDirectory: projectDirectory)
        if result.didChange {
            try? writeMetadata(projectId: projectId, metadata: result.metadata)
        }
        return result.metadata
    }
}

enum ProjectOpenError: LocalizedError {
    case notABlitzProject

    var errorDescription: String? {
        switch self {
        case .notABlitzProject:
            return "Not a Blitz Neo project. The selected folder does not contain .blitz/project.json. Use Import to add an external project."
        }
    }
}
