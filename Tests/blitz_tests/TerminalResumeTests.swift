import Foundation
import Testing
@testable import Blitz

private func withTerminalProject(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("blitz-terminal-resume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

/// Run only the generated final command against a harmless shell function.
/// The PTY cleanup wrapper must never run in the test runner's process group.
private func terminalAgentArguments(
    agent: AIAgent = .codex,
    prompt: String? = nil,
    skipPermissions: Bool = false,
    resumeLastSession: Bool = false
) throws -> [String] {
    let startup = TerminalManager.agentStartupProcess(
        agent: agent, prompt: prompt, skipPermissions: skipPermissions,
        resumeLastSession: resumeLastSession
    )
    let marker = "\nPY\n"
    let range = try #require(startup.args[1].range(of: marker, options: .backwards))
    let command = String(startup.args[1][range.upperBound...])
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "\(agent.cliCommand)() { printf '%s\\0' \"$@\"; };\n" + command]
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
}

@Test func terminalOpeningResumesTheCanonicalProjectWithoutSendingDefaultTask() throws {
    try withTerminalProject { root in
        let real = root.appendingPathComponent("Developer's Project", isDirectory: true)
        let link = root.appendingPathComponent("registered-project", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let options = TerminalOpeningOptions(
            projectPath: link.path, agent: .codex, defaultPrompt: "Submit this app"
        )
        #expect(options.projectPath == real.resolvingSymlinksInPath().path)
        #expect(options.prompt == nil)
        #expect(options.resumeLastSession)
        #expect(TerminalOpeningOptions.codexReuseKey(projectPath: link.path, agent: .codex)
            == TerminalOpeningOptions.codexReuseKey(projectPath: real.path, agent: .codex))
    }
}

@Test func terminalOpeningDoesNotResumeOutsideAValidProjectDirectory() throws {
    try withTerminalProject { root in
        let file = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: file)
        let missing = root.appendingPathComponent("missing")
        let paths: [String?] = [nil, "", file.path, missing.path]
        for path in paths {
            let options = TerminalOpeningOptions(
                projectPath: path, agent: .codex, defaultPrompt: "Do not send this"
            )
            #expect(options.projectPath == nil)
            #expect(options.prompt == nil)
            #expect(!options.resumeLastSession)
            #expect(TerminalOpeningOptions.codexReuseKey(projectPath: path, agent: .codex) == nil)
        }
    }
}

@Test func terminalOpeningPreservesOtherAgentsDefaultPrompts() throws {
    try withTerminalProject { root in
        for agent in [AIAgent.claudeCode, .opencode] {
            let options = TerminalOpeningOptions(
                projectPath: root.path, agent: agent, defaultPrompt: "Existing default task"
            )
            #expect(options.prompt == "Existing default task")
            #expect(!options.resumeLastSession)
            #expect(TerminalOpeningOptions.codexReuseKey(projectPath: root.path, agent: agent) == nil)
            let arguments = try terminalAgentArguments(agent: agent, resumeLastSession: true)
            #expect(arguments.isEmpty)
        }
    }
}

@Test func passiveCodexResumeUsesDirectoryFilteringAndPreservesPermissionPreference() throws {
    #expect(try terminalAgentArguments(resumeLastSession: true) == ["resume", "--last"])
    #expect(try terminalAgentArguments(prompt: "", resumeLastSession: true) == ["resume", "--last"])
    #expect(try terminalAgentArguments(skipPermissions: true, resumeLastSession: true)
        == ["resume", "--last", "--dangerously-bypass-approvals-and-sandbox"])
    #expect(try terminalAgentArguments().isEmpty)
}

@Test func explicitCodexTaskStaysFreshAndShellMetacharactersRemainLiteral() throws {
    let prompt = "Inspect O'Reilly's \"file\"; $(printf expanded) `printf expanded`\nsecond line"
    #expect(try terminalAgentArguments(prompt: prompt, resumeLastSession: true) == [prompt])
    #expect(try terminalAgentArguments(prompt: prompt, skipPermissions: true, resumeLastSession: true)
        == ["--dangerously-bypass-approvals-and-sandbox", prompt])
    #expect(try terminalAgentArguments(agent: .claudeCode, prompt: prompt, skipPermissions: true,
                                     resumeLastSession: true)
        == ["--dangerously-skip-permissions", prompt])
    #expect(try terminalAgentArguments(agent: .opencode, prompt: prompt, skipPermissions: true,
                                     resumeLastSession: true) == [prompt])
}

@Test func projectSessionRegistryReusesPreferredLiveTaskWithoutCrossingProjects() {
    var registry = AgentSessionRegistry()
    let older = UUID(), latest = UUID(), otherProject = UUID()
    registry.register(older, for: "project-A")
    registry.register(latest, for: "project-A")
    registry.register(otherProject, for: "project-B")
    let live: Set<UUID> = [older, latest, otherProject]

    #expect(registry.existing(for: "project-A", activeIDs: live) == latest)
    #expect(registry.existing(for: "project-A", activeIDs: live, preferredID: older) == older)
    #expect(registry.existing(for: "project-A", activeIDs: live, preferredID: otherProject) == latest)
    #expect(registry.existing(for: "project-B", activeIDs: live, preferredID: latest) == otherProject)
    #expect(registry.existing(for: "unknown-project", activeIDs: live) == nil)
}

@Test func projectSessionRegistryFallsBackToOlderLiveTaskWhenLatestTerminates() {
    var registry = AgentSessionRegistry()
    let older = UUID(), latest = UUID()
    registry.register(older, for: "project")
    registry.register(latest, for: "project")

    #expect(registry.existing(for: "project", activeIDs: [older], preferredID: latest) == older)
    #expect(registry.existing(for: "project", activeIDs: []) == nil)
    #expect(registry.existing(for: "project", activeIDs: [older, latest]) == nil)
}
