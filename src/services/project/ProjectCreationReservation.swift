// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Darwin
import Foundation

/// A new project must own its directory before metadata or templates are written.
enum ProjectCreationReservation {
    static let markerName = "scaffold-reservation"

    static func projectID(for name: String) throws -> String {
        let id = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard id.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw ProjectSetupService.SetupError(message: "Enter a project name containing letters or numbers.")
        }
        return id
    }

    static func reserve(name: String, in baseDirectory: URL) throws -> (id: String, directory: URL) {
        let id = try projectID(for: name)
        let fm = FileManager.default
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let directory = baseDirectory.appendingPathComponent(id, isDirectory: true)
        // mkdir is exclusive even for an existing directory or a dangling symlink.
        guard directory.path.withCString({ Darwin.mkdir($0, 0o755) }) == 0 else {
            if errno == EEXIST {
                throw ProjectSetupService.SetupError(message: "A project folder already exists for this name. Choose a different name; the existing project was not changed.")
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let blitz = directory.appendingPathComponent(".blitz", isDirectory: true)
        try fm.createDirectory(at: blitz, withIntermediateDirectories: false)
        try Data(UUID().uuidString.utf8).write(to: blitz.appendingPathComponent(markerName), options: .withoutOverwriting)
        return (id, directory)
    }

    static func validate(_ directory: URL) throws -> Data {
        let fm = FileManager.default
        let blitz = directory.appendingPathComponent(".blitz", isDirectory: true)
        let marker = blitz.appendingPathComponent(markerName)
        guard (try? fm.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory,
              (try? fm.attributesOfItem(atPath: blitz.path)[.type]) as? FileAttributeType == .typeDirectory,
              (try? fm.attributesOfItem(atPath: marker.path)[.type]) as? FileAttributeType == .typeRegular,
              let token = try? Data(contentsOf: marker),
              UUID(uuidString: String(decoding: token, as: UTF8.self)) != nil else {
            throw ProjectSetupService.SetupError(message: "This folder is not a reserved new project. Existing project files will not be replaced.")
        }
        return token
    }
}
