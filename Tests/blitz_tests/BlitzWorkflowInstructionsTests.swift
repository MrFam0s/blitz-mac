import Foundation
import Testing
@testable import Blitz

@Suite struct BlitzWorkflowInstructionsTests {
    private let body = "## Blitz Neo workflows\nUse the bundled skill when asked to submit an update."

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blitz-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url.resolvingSymlinksInPath()
    }

    @Test func preservesAuthoredBytesAndPrependsEvenForLargeDocuments() throws {
        let authored = "# Projektregeln\r\nUmlaute: Äß; e\u{301}.\r\n" + String(repeating: "Keep the existing product and safety rules.\r\n", count: 5000)
        let updated = try BlitzWorkflowInstructions.updatedDocument(authored, body: body)
        #expect(updated.hasPrefix(BlitzWorkflowInstructions.beginMarker + "\n"))
        #expect(Data(updated.utf8).suffix(Data(authored.utf8).count) == Data(authored.utf8))
        #expect(try BlitzWorkflowInstructions.updatedDocument(updated, body: body) == updated)
        let newBody = "## Updated routing\nKeep the exact saved app identity."
        let replacement = try BlitzWorkflowInstructions.updatedDocument(updated, body: newBody)
        #expect(replacement.contains(newBody))
        #expect(!replacement.contains(body))
        #expect(Data(replacement.utf8).suffix(Data(authored.utf8).count) == Data(authored.utf8))
    }

    @Test func replacementPreservesTextOutsideManagedBlockAndAcceptsCRLF() throws {
        let original = "# Before\r\n" + BlitzWorkflowInstructions.beginMarker + "\r\nold\r\n" + BlitzWorkflowInstructions.endMarker + "\r\n# After\r\n"
        let updated = try BlitzWorkflowInstructions.updatedDocument(original, body: body)
        #expect(updated.hasPrefix("# Before\r\n"))
        #expect(updated.hasSuffix("\r\n# After\r\n"))
        #expect(updated.contains(body))
        #expect(try BlitzWorkflowInstructions.updatedDocument(updated, body: body) == updated)
    }

    @Test func malformedAndDuplicateMarkersAreRejected() throws {
        let begin = BlitzWorkflowInstructions.beginMarker
        let end = BlitzWorkflowInstructions.endMarker
        let documents = [begin, end, "\(end)\n\(begin)", "\(begin)\n\(begin)\n\(end)",
                         "\(begin)\n\(end)\n\(end)", "inline \(begin)\n\(end)",
                         "\(begin)\n\(end) trailing", "<!-- BEGIN BLITZ NEO WORKFLOW ROUTING\n\(end)"]
        for document in documents {
            #expect(throws: Error.self) { try BlitzWorkflowInstructions.updatedDocument(document, body: body) }
        }
        #expect(throws: Error.self) { try BlitzWorkflowInstructions.updatedDocument("Authored", body: "\n ") }
        #expect(throws: Error.self) { try BlitzWorkflowInstructions.updatedDocument("Authored", body: begin) }
    }

    @Test func installsBothRootsAndExistingOverridePreservingPermissionsAndIdentityWhenUnchanged() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let override = project.appendingPathComponent("AGENTS.override.md")
        let authored = "# Override\nDo not remove this directive.\n"
        try authored.write(to: override, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: override.path)
        try BlitzWorkflowInstructions.install(projectDirectory: project, body: body)
        for name in ["AGENTS.md", "CLAUDE.md", "AGENTS.override.md"] {
            let url = project.appendingPathComponent(name)
            #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix(BlitzWorkflowInstructions.beginMarker))
        }
        #expect(try String(contentsOf: override, encoding: .utf8).hasSuffix(authored))
        let attributes = try FileManager.default.attributesOfItem(atPath: override.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        try BlitzWorkflowInstructions.install(projectDirectory: project, body: body)
        let unchanged = try FileManager.default.attributesOfItem(atPath: override.path)
        #expect(attributes[.systemFileNumber] as? NSNumber == unchanged[.systemFileNumber] as? NSNumber)
        #expect(attributes[.modificationDate] as? Date == unchanged[.modificationDate] as? Date)
        #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).sorted() == ["AGENTS.md", "AGENTS.override.md", "CLAUDE.md"])
    }

    @Test func supportsImportedProjectAliasWithoutCreatingAnOverride() throws {
        let project = try temporaryDirectory()
        let registry = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project); try? FileManager.default.removeItem(at: registry) }
        let alias = registry.appendingPathComponent("ImportedApp")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        try BlitzWorkflowInstructions.install(projectDirectory: alias, body: body)
        #expect(try String(contentsOf: project.appendingPathComponent("AGENTS.md"), encoding: .utf8).contains(body))
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("AGENTS.override.md").path))
    }

    @Test func rejectsDocumentSymlinksIncludingDanglingAndOverrideBeforeAnyWrite() throws {
        let project = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project); try? FileManager.default.removeItem(at: outside) }
        let external = outside.appendingPathComponent("private.md")
        try "External instructions".write(to: external, atomically: true, encoding: .utf8)
        for name in ["AGENTS.md", "CLAUDE.md", "AGENTS.override.md"] {
            for target in [external, outside.appendingPathComponent("missing.md")] {
                let link = project.appendingPathComponent(name)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                #expect(throws: Error.self) { try BlitzWorkflowInstructions.install(projectDirectory: project, body: body) }
                #expect(try FileManager.default.contentsOfDirectory(atPath: project.path) == [name])
                #expect(try String(contentsOf: external, encoding: .utf8) == "External instructions")
                #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("missing.md").path))
                try FileManager.default.removeItem(at: link)
            }
        }
    }

    @Test func malformedSecondDocumentPreventsPartialBatchUpdate() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let agents = project.appendingPathComponent("AGENTS.md")
        let claude = project.appendingPathComponent("CLAUDE.md")
        try "Original agents".write(to: agents, atomically: true, encoding: .utf8)
        try BlitzWorkflowInstructions.beginMarker.write(to: claude, atomically: true, encoding: .utf8)
        #expect(throws: Error.self) { try BlitzWorkflowInstructions.install(projectDirectory: project, body: body) }
        #expect(try String(contentsOf: agents, encoding: .utf8) == "Original agents")
        #expect(try String(contentsOf: claude, encoding: .utf8) == BlitzWorkflowInstructions.beginMarker)
    }

    @Test(arguments: [true, false])
    func concurrentSaveBetweenFinalCheckAndRenameIsPreserved(atomicSave: Bool) throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let agents = project.appendingPathComponent("AGENTS.md")
        let claude = project.appendingPathComponent("CLAUDE.md")
        try "Original agents".write(to: agents, atomically: true, encoding: .utf8)
        try "Original Claude".write(to: claude, atomically: true, encoding: .utf8)
        let authoredEdit = "New authored instruction saved during installation.\n"
        var caught: Error?
        do {
            try BlitzWorkflowInstructions.install(projectDirectory: project, body: body) { name in
                guard name == "AGENTS.md" else { return }
                try authoredEdit.write(to: agents, atomically: atomicSave, encoding: .utf8)
            }
        } catch { caught = error }
        let error = try #require(caught)
        let retained = try #require(FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".blitz-workflow-conflict-") })
        #expect(error.localizedDescription.contains(retained.path))
        #expect(error.localizedDescription.contains("Reconcile"))
        #expect(try String(contentsOf: retained, encoding: .utf8) == authoredEdit)
        #expect(try String(contentsOf: claude, encoding: .utf8) == "Original Claude")
        #expect(try String(contentsOf: agents, encoding: .utf8).hasPrefix(BlitzWorkflowInstructions.beginMarker))
    }

    @Test func rejectsNonUTF8OrDirectoryWithoutReplacingOtherInstructions() throws {
        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let claude = project.appendingPathComponent("CLAUDE.md")
        try Data([0xff, 0xfe, 0xff]).write(to: claude)
        #expect(throws: Error.self) { try BlitzWorkflowInstructions.install(projectDirectory: project, body: body) }
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("AGENTS.md").path))
        try FileManager.default.removeItem(at: claude)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: false)
        #expect(throws: Error.self) { try BlitzWorkflowInstructions.install(projectDirectory: project, body: body) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: claude.path).isEmpty)
    }
}
