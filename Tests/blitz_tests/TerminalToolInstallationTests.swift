import Foundation
import Testing
@testable import Blitz

private struct TerminalToolFixture {
    let home: URL
    var root: URL { home.appendingPathComponent(".blitz") }

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-tools-\(UUID().uuidString)-user's $SHELL")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: home) }

    func write(_ relativePath: String, contents: String = "#!/bin/sh\nprintf '%s\\n' \"$1\"\n", executable: Bool = true) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    func inspect() -> [TerminalToolInstallation] { TerminalToolInstallation.inspect(blitzRoot: root) }

    func shortcutState(enabled: Bool) -> TerminalShellShortcutState {
        TerminalShellShortcutState.inspect(enabled: enabled, homeDirectory: home, blitzRoot: root)
    }
}

@Test func terminalToolAvailabilityDoesNotDependOnOptionalShellSetup() throws {
    let fixture = try TerminalToolFixture()
    defer { fixture.cleanup() }
    #expect(fixture.inspect().allSatisfy { $0.availability == .missing })

    try fixture.write("bin/asc")
    #expect(fixture.inspect().first?.availability == .incomplete)
    try fixture.write("bin/ascd")
    try fixture.write("bin/blitz-neo")
    try fixture.write("blitz-macos-mcp")
    #expect(fixture.inspect().allSatisfy { $0.availability == .installed })
    #expect(fixture.shortcutState(enabled: false) == .unconfigured)
}

@Test func terminalToolAvailabilityRejectsMissingOrNonExecutableHelpers() throws {
    let fixture = try TerminalToolFixture()
    defer { fixture.cleanup() }
    try fixture.write("bin/asc")
    try fixture.write("bin/ascd", executable: false)
    try fixture.write("bin/blitz-neo")
    #expect(fixture.inspect().allSatisfy { $0.availability == .incomplete })

    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("bin/ascd"))
    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("bin/ascd"), withIntermediateDirectories: true)
    #expect(fixture.inspect().first?.availability == .incomplete)
}

@Test func terminalToolCommandRemainsRunnableWithShellCharactersInHomePath() throws {
    let fixture = try TerminalToolFixture()
    defer { fixture.cleanup() }
    try fixture.write("bin/asc")
    try fixture.write("bin/ascd")
    let tool = try #require(fixture.inspect().first)
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", tool.shellCommand + " --help"]
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(data: data, encoding: .utf8) == "--help\n")
}

@Test func terminalShellShortcutStatusChecksFilesInsteadOfOnlySavedSetting() throws {
    let fixture = try TerminalToolFixture()
    defer { fixture.cleanup() }
    #expect(fixture.shortcutState(enabled: true) == .incomplete)
    let block = "# >>> Blitz shell integration >>>\n. ~/.blitz/shell/init.sh\n# <<< Blitz shell integration <<<\n"
    try block.write(to: fixture.home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    #expect(fixture.shortcutState(enabled: true) == .incomplete)
    try fixture.write("shell/init.sh", contents: "export PATH=\"$HOME/.blitz/bin:$PATH\"\n", executable: false)
    #expect(fixture.shortcutState(enabled: true) == .configured)
    #expect(fixture.shortcutState(enabled: false) == .incomplete)
}

@Test func terminalShellShortcutStatusDoesNotTreatUnrelatedPATHAsBlitzManaged() throws {
    let fixture = try TerminalToolFixture()
    defer { fixture.cleanup() }
    try "export PATH=\"$HOME/.local/bin:$PATH\"\n".write(
        to: fixture.home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
    )
    #expect(fixture.shortcutState(enabled: false) == .unconfigured)
}
