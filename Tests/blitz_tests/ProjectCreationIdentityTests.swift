import Foundation
import Testing
@testable import Blitz

@Suite struct ProjectCreationIdentityTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blitz-project-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func spec() -> ProjectTemplateSpec {
        ProjectTemplateSpec(templateName: "fixture", missingTemplateMessage: "missing", replacements: [:], cleanupPaths: [], logPrefix: "test")
    }

    @Test func emptyAndPunctuationNamesCannotReserveProjectRoot() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(baseDirectory: root)
        for name in ["", "   ", "../", "--", "🎉"] {
            #expect(throws: (any Error).self) { try repository.createProject(metadata: BlitzProjectMetadata(name: name, type: .swift)) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func normalizedNameCollisionPreservesMetadataAndFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(baseDirectory: root)
        let id = try repository.createProject(metadata: BlitzProjectMetadata(name: "ClubBundle", type: .swift, bundleIdentifier: "org.amosystems.ClubBundle"))
        let project = root.appendingPathComponent(id)
        let metadataBefore = try Data(contentsOf: project.appendingPathComponent(".blitz/project.json"))
        try Data("valuable source".utf8).write(to: project.appendingPathComponent("Main.swift"))
        #expect(throws: (any Error).self) { try repository.createProject(metadata: BlitzProjectMetadata(name: "clubbundle", type: .reactNative)) }
        #expect(try Data(contentsOf: project.appendingPathComponent(".blitz/project.json")) == metadataBefore)
        #expect(try String(contentsOf: project.appendingPathComponent("Main.swift"), encoding: .utf8) == "valuable source")
    }

    @Test func existingAndDanglingSymlinksCannotBeUsedForNewProject() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("external")
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: source.appendingPathComponent("sentinel"))
        try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent("clubbundle"), withDestinationURL: source)
        try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent("missing"), withDestinationURL: root.appendingPathComponent("does-not-exist"))
        let repository = ProjectRepository(baseDirectory: projects)
        for name in ["ClubBundle", "Missing"] {
            #expect(throws: (any Error).self) { try repository.createProject(metadata: BlitzProjectMetadata(name: name, type: .swift)) }
        }
        #expect(try String(contentsOf: source.appendingPathComponent("sentinel"), encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent(".blitz").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: projects.appendingPathComponent("clubbundle").path) == source.path)
    }

    @Test func concurrentReservationsHaveExactlyOneWinner() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    (try? ProjectRepository(baseDirectory: root).createProject(metadata: BlitzProjectMetadata(name: "ClubBundle", type: .swift))) != nil
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        #expect(successes == 1)
        #expect(try ProjectRepository(baseDirectory: root).readMetadataFromDirectory(root.appendingPathComponent("clubbundle"))?.name == "ClubBundle")
    }

    @Test func scaffoldingRejectsUnreservedFolderAndSymlinkTarget() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = root.appendingPathComponent("template")
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: template.appendingPathComponent("source"))
        try Data("keep".utf8).write(to: existing.appendingPathComponent("source"))
        #expect(throws: (any Error).self) { try ProjectTemplateScaffolder.scaffold(spec: spec(), templateURL: template, projectDirectory: existing) }
        let reserved = try ProjectCreationReservation.reserve(name: "Reserved", in: root)
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: reserved.directory)
        #expect(throws: (any Error).self) { try ProjectTemplateScaffolder.scaffold(spec: spec(), templateURL: template, projectDirectory: linked) }
        #expect(try String(contentsOf: existing.appendingPathComponent("source"), encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: reserved.directory.appendingPathComponent("source").path))
    }

    @Test func templateCollisionNeverOverwritesExistingContent() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = root.appendingPathComponent("template")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: false)
        try Data("template".utf8).write(to: template.appendingPathComponent("source"))
        let reserved = try ProjectCreationReservation.reserve(name: "New App", in: root)
        try Data("keep".utf8).write(to: reserved.directory.appendingPathComponent("source"))
        #expect(throws: (any Error).self) { try ProjectTemplateScaffolder.scaffold(spec: spec(), templateURL: template, projectDirectory: reserved.directory) }
        #expect(try String(contentsOf: reserved.directory.appendingPathComponent("source"), encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".blitz-stage-") })
    }

    @Test func successfulScaffoldingPreservesMetadataAndCannotRunTwice() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = root.appendingPathComponent("template")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: false)
        try Data("template".utf8).write(to: template.appendingPathComponent("source"))
        let repository = ProjectRepository(baseDirectory: root.appendingPathComponent("projects"))
        let id = try repository.createProject(metadata: BlitzProjectMetadata(name: "ClubBundle", type: .swift))
        let project = repository.baseDirectory.appendingPathComponent(id)
        let metadataBefore = try Data(contentsOf: project.appendingPathComponent(".blitz/project.json"))
        try ProjectTemplateScaffolder.scaffold(spec: spec(), templateURL: template, projectDirectory: project)
        #expect(try Data(contentsOf: project.appendingPathComponent(".blitz/project.json")) == metadataBefore)
        #expect(try String(contentsOf: project.appendingPathComponent("source"), encoding: .utf8) == "template")
        #expect(throws: (any Error).self) { try ProjectTemplateScaffolder.scaffold(spec: spec(), templateURL: template, projectDirectory: project) }
    }

    @Test(arguments: [ProjectPlatform.iOS, .macOS])
    func swiftTemplatePreservesOriginalCapitalizationAndDisplayName(platform: ProjectPlatform) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "ClubBundle Café \"Plus\""
        let repository = ProjectRepository(baseDirectory: root)
        let id = try repository.createProject(metadata: BlitzProjectMetadata(name: name, type: .swift, platform: platform))
        let project = root.appendingPathComponent(id)
        if platform == .iOS {
            try await SwiftProjectSetupService.setup(projectId: id, projectName: name, projectPath: project.path, onStep: { _ in })
        } else {
            try await MacSwiftProjectSetupService.setup(projectId: id, projectName: name, projectPath: project.path, onStep: { _ in })
        }
        let technicalName = "ClubBundleCafePlus"
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: project.appendingPathComponent("\(technicalName)/Info.plist")), format: nil) as? [String: Any]
        #expect(plist?["CFBundleDisplayName"] as? String == name)
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: project) == ["dev.blitz.ClubBundleCafePlus"])
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("\(technicalName).xcodeproj/project.pbxproj").path))
    }

    @Test func numericAndNonLatinNamesKeepDistinctValidTechnicalIdentities() {
        let names = ["123", "456", "東京", "大阪"]
        let technical = names.map(SwiftProjectSetupService.toSwiftAppName)
        #expect(technical[0] == "App123")
        #expect(Set(technical).count == names.count)
        #expect(technical.allSatisfy { $0.range(of: "^[A-Za-z][A-Za-z0-9]*$", options: .regularExpression) != nil })
    }

    @Test func reactNativeNamesAreStructuredJSONAndTechnicalNamesStayValid() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "ClubBundle Café \"Plus\" \\ Edition"
        let repository = ProjectRepository(baseDirectory: root)
        let id = try repository.createProject(metadata: BlitzProjectMetadata(name: name, type: .reactNative))
        let project = root.appendingPathComponent(id)
        try await ProjectSetupService.setup(projectId: id, projectName: name, projectPath: project.path, onStep: { _ in })
        let app = try JSONSerialization.jsonObject(with: Data(contentsOf: project.appendingPathComponent("app.json"))) as? [String: Any]
        let package = try JSONSerialization.jsonObject(with: Data(contentsOf: project.appendingPathComponent("package.json"))) as? [String: Any]
        #expect(app?["name"] as? String == "ClubBundleCafePlusEdition")
        #expect(app?["displayName"] as? String == name)
        #expect(package?["name"] as? String == "clubbundlecafeplusedition")
        #expect(package?["dependencies"] != nil)
    }

    @Test func reimportPreservesSavedIdentityAndBuildSettings() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(baseDirectory: root.appendingPathComponent("registry"))
        let project = root.appendingPathComponent("renamed-folder")
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = BlitzProjectMetadata(name: "ClubBundle Original", type: .swift, platform: .macOS,
            bundleIdentifier: "org.amosystems.ClubBundle", createdAt: created, simulatorUDID: "saved-device",
            buildSettings: BuildSettings(scheme: "ChosenScheme", configuration: "Release", destination: "platform=macOS"), teamId: "saved-team")
        try repository.writeMetadataToDirectory(project, metadata: saved)
        let imported = try repository.metadataForImport(directory: project, type: .swift, platform: .macOS, selectedBundleID: nil)
        #expect(imported.name == saved.name)
        #expect(imported.bundleIdentifier == saved.bundleIdentifier)
        #expect(imported.createdAt == created)
        #expect(imported.simulatorUDID == saved.simulatorUDID)
        #expect(imported.buildSettings?.scheme == "ChosenScheme")
        #expect(imported.buildSettings?.configuration == "Release")
        #expect(imported.buildSettings?.destination == "platform=macOS")
        #expect(imported.teamId == "saved-team")
        let changed = try repository.metadataForImport(directory: project, type: .swift, platform: .macOS, selectedBundleID: "org.amosystems.ClubBundleMac")
        #expect(changed.bundleIdentifier == "org.amosystems.ClubBundleMac")
        #expect(changed.name == saved.name)
        #expect(changed.buildSettings?.scheme == "ChosenScheme")
    }

    @Test func malformedExistingMetadataPreventsReimportReplacement() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataDirectory = root.appendingPathComponent(".blitz")
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: false)
        let original = Data("{broken but recoverable".utf8)
        try original.write(to: metadataDirectory.appendingPathComponent("project.json"))
        #expect(throws: (any Error).self) {
            try ProjectRepository(baseDirectory: root).metadataForImport(directory: root, type: .swift, platform: .iOS, selectedBundleID: nil)
        }
        #expect(try Data(contentsOf: metadataDirectory.appendingPathComponent("project.json")) == original)
    }
}
