import Foundation
import Testing
@testable import Blitz

@Test func creationSkillIsSynchronizedBeforeLaunch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source/asc-app-create-ui")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try "new instructions".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try "new script".write(to: source.appendingPathComponent("scripts/create_app.py"), atomically: true, encoding: .utf8)
    let project = root.appendingPathComponent("project")
    for prefix in [".claude", ".agents"] {
        let old = project.appendingPathComponent("\(prefix)/skills/asc-app-create-ui")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try "old instructions".write(to: old.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }
    let service = ProjectAgentConfigService(baseDirectory: root)
    try service.prepareBundledCreationSkill(projectDir: project, sourceSkillsDirectory: source.deletingLastPathComponent())
    for prefix in [".claude", ".agents"] {
        let installed = project.appendingPathComponent("\(prefix)/skills/asc-app-create-ui")
        #expect(try String(contentsOf: installed.appendingPathComponent("SKILL.md")) == "new instructions")
        #expect(try String(contentsOf: installed.appendingPathComponent("scripts/create_app.py")) == "new script")
    }
}

@Test func incompleteCreationSkillPreservesInstalledInstructions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source/asc-app-create-ui")
    let installed = root.appendingPathComponent("project/.agents/skills/asc-app-create-ui")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    try "incomplete".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try "existing".write(to: installed.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let service = ProjectAgentConfigService(baseDirectory: root)
    #expect(throws: (any Error).self) {
        try service.prepareBundledCreationSkill(projectDir: root.appendingPathComponent("project"), sourceSkillsDirectory: source.deletingLastPathComponent())
    }
    #expect(try String(contentsOf: installed.appendingPathComponent("SKILL.md")) == "existing")
}

@Test func creationSkillReplacementPreservesExternalSymlinkTarget() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source/asc-app-create-ui")
    try fm.createDirectory(at: source.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try "new".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try "script".write(to: source.appendingPathComponent("scripts/create_app.py"), atomically: true, encoding: .utf8)
    let external = root.appendingPathComponent("external")
    try fm.createDirectory(at: external, withIntermediateDirectories: true)
    try "keep".write(to: external.appendingPathComponent("important.txt"), atomically: true, encoding: .utf8)
    let project = root.appendingPathComponent("project")
    for (prefix, target) in [(".claude", external), (".agents", root.appendingPathComponent("missing-external"))] {
        let skills = project.appendingPathComponent("\(prefix)/skills")
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: skills.appendingPathComponent("asc-app-create-ui"), withDestinationURL: target)
    }
    try ProjectAgentConfigService(baseDirectory: root).prepareBundledCreationSkill(projectDir: project, sourceSkillsDirectory: source.deletingLastPathComponent())
    #expect(try String(contentsOf: external.appendingPathComponent("important.txt")) == "keep")
    for prefix in [".claude", ".agents"] {
        #expect(try String(contentsOf: project.appendingPathComponent("\(prefix)/skills/asc-app-create-ui/scripts/create_app.py")) == "script")
    }
}
