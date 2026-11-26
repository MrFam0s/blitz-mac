import Foundation
import Testing
@testable import Blitz

@Test func ensureMCPConfigUsesDetachedLauncherForBlitzIphone() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("blitz-agent-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let service = ProjectAgentConfigService(baseDirectory: tempDirectory, globalCodexConfig: tempDirectory.appendingPathComponent("missing-global.toml"), launcherDirectory: tempDirectory.appendingPathComponent("bin"))
    service.ensureMCPConfig(in: tempDirectory)

    let launcherPath = tempDirectory.appendingPathComponent("bin").appendingPathComponent("blitz-detached-mcp").path
    #expect(FileManager.default.isExecutableFile(atPath: launcherPath))

    let codexConfigURL = tempDirectory.appendingPathComponent(".codex/config.toml")
    let codexConfig = try String(contentsOf: codexConfigURL, encoding: .utf8)
    #expect(codexConfig.contains("command = \"\(launcherPath)\""))
    let bundledArgs = [BlitzPaths.nodeDir.appendingPathComponent("node").path,
                       BlitzPaths.nodeDir.appendingPathComponent("iphone-mcp").path]
    let expectedToml = bundledArgs.map { "\"\($0)\"" }.joined(separator: ", ")
    #expect(codexConfig.contains("args = [\(expectedToml)]"))

    let mcpConfigURL = tempDirectory.appendingPathComponent(".mcp.json")
    let mcpConfigData = try Data(contentsOf: mcpConfigURL)
    let root = try #require(JSONSerialization.jsonObject(with: mcpConfigData) as? [String: Any])
    let servers = try #require(root["mcpServers"] as? [String: Any])
    let blitzIphone = try #require(servers["blitz-iphone"] as? [String: Any])
    #expect(blitzIphone["command"] as? String == launcherPath)
    #expect(blitzIphone["args"] as? [String] == bundledArgs)
    let openCode = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: tempDirectory.appendingPathComponent("opencode.json"))) as? [String: Any])
    let openCodeServers = try #require(openCode["mcp"] as? [String: Any])
    let openCodeIphone = try #require(openCodeServers["blitz-iphone"] as? [String: Any])
    #expect(openCodeIphone["command"] as? [String] == [launcherPath] + bundledArgs)
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
    let service = ProjectAgentConfigService(baseDirectory: directory, globalCodexConfig: global, launcherDirectory: directory.appendingPathComponent("bin"))
    service.ensureMCPConfig(in: directory)
    #expect(try String(contentsOf: local, encoding: .utf8) == settings)
    try FileManager.default.removeItem(at: local)
    service.ensureMCPConfig(in: directory)
    let created = try String(contentsOf: local, encoding: .utf8)
    #expect(created.contains("project_doc_fallback_filenames"))
    #expect(!created.contains("mcp_servers"))
}

@Test func claudePermissionToggleRevokesManagedToolsAndPreservesUserRules() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.local.json")
    let existing: [String: Any] = [
        "model": "user-model",
        "enabledMcpjsonServers": ["user-server", "blitz-ios"],
        "permissions": [
            "allow": ["Bash(git status:*)", "mcp__user-server__lookup", "mcp__blitz-ios__tap"],
            "deny": ["Bash(rm:*)"],
            "ask": ["Bash(git push:*)"],
        ],
    ]
    try JSONSerialization.data(withJSONObject: existing).write(to: file)
    let minimal = ["mcp__blitz-macos__app_get_state"]

    ProjectAgentConfigService.updateClaudeSettings(at: file, whitelistBlitzMCP: true,
        allowASCCLICalls: true, initialAllow: [], minimalBlitzAllow: minimal)
    let enabled = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let enabledPermissions = try #require(enabled["permissions"] as? [String: Any])
    let enabledAllow = try #require(enabledPermissions["allow"] as? [String])
    #expect(enabledAllow.contains("mcp__blitz-macos__asc_fill_form"))
    #expect(enabledAllow.contains("mcp__blitz-iphone__device_action"))
    #expect(enabledAllow.contains("Bash(asc:*)"))

    ProjectAgentConfigService.updateClaudeSettings(at: file, whitelistBlitzMCP: false,
        allowASCCLICalls: false, initialAllow: [], minimalBlitzAllow: minimal)
    let disabled = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let disabledPermissions = try #require(disabled["permissions"] as? [String: Any])
    let disabledAllow = try #require(disabledPermissions["allow"] as? [String])
    #expect(Set(disabledAllow) == Set(["Bash(git status:*)", "mcp__user-server__lookup"] + minimal))
    #expect(disabledPermissions["deny"] as? [String] == ["Bash(rm:*)"])
    #expect(disabledPermissions["ask"] as? [String] == ["Bash(git push:*)"])
    #expect(disabled["model"] as? String == "user-model")
    #expect(disabled["enabledMcpjsonServers"] as? [String] == ["user-server", "blitz-macos", "blitz-iphone"])
}

@Test func claudePermissionToggleCreatesMissingAllowList() throws {
    for existing in [[:], ["permissions": ["deny": ["Bash(rm:*)"]]]] as [[String: Any]] {
        let updated = ProjectAgentConfigService.reconciledClaudeSettings(existing,
            whitelistBlitzMCP: true, allowASCCLICalls: true,
            initialAllow: [], minimalBlitzAllow: [])
        let permissions = try #require(updated["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String])
        #expect(allow.contains("Bash(asc:*)"))
        #expect(allow.contains("mcp__blitz-iphone__device_action"))
        if existing["permissions"] != nil {
            #expect(permissions["deny"] as? [String] == ["Bash(rm:*)"])
        }
    }
}

@Test func claudeGlobalPermissionToggleRetainsOnlySetupExceptionsWhenDisabled() throws {
    let minimal = ["mcp__blitz-macos__asc_set_credentials", "mcp__blitz-macos__asc_web_auth"]
    let enabled = ProjectAgentConfigService.reconciledClaudeSettings([:],
        whitelistBlitzMCP: true, allowASCCLICalls: false,
        initialAllow: ["Bash(python3:*)"], minimalBlitzAllow: minimal)
    let disabled = ProjectAgentConfigService.reconciledClaudeSettings(enabled,
        whitelistBlitzMCP: false, allowASCCLICalls: false,
        initialAllow: ["Bash(python3:*)"], minimalBlitzAllow: minimal)
    let permissions = try #require(disabled["permissions"] as? [String: Any])
    #expect(Set(permissions["allow"] as? [String] ?? []) == Set(["Bash(python3:*)"] + minimal))
}

@Test func claudePermissionUpdatePreservesMalformedExistingFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.local.json")
    let original = "{ user-edited unfinished configuration"
    try original.write(to: file, atomically: true, encoding: .utf8)
    ProjectAgentConfigService.updateClaudeSettings(at: file, whitelistBlitzMCP: true,
        allowASCCLICalls: true, initialAllow: [], minimalBlitzAllow: [])
    #expect(try String(contentsOf: file, encoding: .utf8) == original)
}
