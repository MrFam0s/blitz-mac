import Foundation
import Testing
@testable import Blitz

@Test func ensureMCPConfigUsesDetachedLauncherForBlitzIphone() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("blitz-agent-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let service = ProjectAgentConfigService(baseDirectory: tempDirectory, globalCodexConfig: tempDirectory.appendingPathComponent("missing-global.toml"))
    service.ensureMCPConfig(in: tempDirectory)

    let launcherPath = BlitzPaths.bin.appendingPathComponent("blitz-detached-mcp").path
    #expect(FileManager.default.isExecutableFile(atPath: launcherPath))

    let codexConfigURL = tempDirectory.appendingPathComponent(".codex/config.toml")
    let codexConfig = try String(contentsOf: codexConfigURL, encoding: .utf8)
    #expect(codexConfig.contains("command = \"\(launcherPath)\""))
    #expect(
        codexConfig.contains("dist/cli.js")
        || codexConfig.contains("node-runtime/bin/iphone-mcp")
        || codexConfig.contains("\"-y\", \"@blitzdev/iphone-mcp\"")
    )

    let mcpConfigURL = tempDirectory.appendingPathComponent(".mcp.json")
    let mcpConfigData = try Data(contentsOf: mcpConfigURL)
    let root = try #require(JSONSerialization.jsonObject(with: mcpConfigData) as? [String: Any])
    let servers = try #require(root["mcpServers"] as? [String: Any])
    let blitzIphone = try #require(servers["blitz-iphone"] as? [String: Any])
    #expect(blitzIphone["command"] as? String == launcherPath)
}

@Test func globalCodexMCPPreservesProjectSettings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let global = directory.appendingPathComponent("global.toml")
    try "[mcp_servers.blitz_macos]\ncommand = \"mac\"\n[mcp_servers.\"blitz-iphone\"]\ncommand = \"phone\"\n".write(to: global, atomically: true, encoding: .utf8)
    let local = directory.appendingPathComponent(".codex/config.toml")
    let settings = "model = \"my-model\"\n[mcp_servers.example]\ncommand = \"example\"\n"
    try settings.write(to: local, atomically: true, encoding: .utf8)
    let service = ProjectAgentConfigService(baseDirectory: directory, globalCodexConfig: global)
    service.ensureMCPConfig(in: directory)
    #expect(try String(contentsOf: local, encoding: .utf8) == settings)
    try FileManager.default.removeItem(at: local)
    service.ensureMCPConfig(in: directory)
    let created = try String(contentsOf: local, encoding: .utf8)
    #expect(created.contains("project_doc_fallback_filenames"))
    #expect(!created.contains("mcp_servers"))
}
