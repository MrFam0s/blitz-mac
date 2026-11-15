import Foundation
import Testing
@testable import Blitz

@Test func mcpIntegrationRecognizesGlobalCodexSelectionAndDisabledPhone() {
    let config = """
    [mcp_servers.'blitz_macos'] # existing user choice
    command = "/Users/test/.blitz/blitz-macos-mcp"
    enabled_tools = [
        "app_get_state",
    ]
    [mcp_servers."blitz-iphone"]
    command = "/Users/test/.blitz/bin/blitz-detached-mcp"
    enabled = false # deliberately disabled
    [mcp_servers.other]
    enabled = true
    """
    let result = MCPIntegrationConfiguration.inspect(agent: .codex, data: Data(config.utf8), file: URL(fileURLWithPath: "/tmp/config.toml"))
    #expect(result.app == .restricted)
    #expect(result.iphone == .disabled)
}

@Test func mcpIntegrationDoesNotCountCommentsOrUnrelatedServerOptions() {
    let config = """
    # [mcp_servers.blitz_macos]
    [mcp_servers."blitz-iphone"]
    command = "phone"
    [mcp_servers.other]
    enabled = false
    enabled_tools = []
    """
    let result = MCPIntegrationConfiguration.inspect(agent: .codex, data: Data(config.utf8), file: URL(fileURLWithPath: "/tmp/config.toml"))
    #expect(result.app == .missing)
    #expect(result.iphone == .present)
}

@Test func mcpIntegrationDoesNotMistakeUncertainTOMLForAnAbsentOrWorkingEntry() {
    let cases = [
        "instructions = \"\"\"\n[mcp_servers.blitz_macos]\ncommand = \"example\"\n\"\"\"",
        "[mcp_servers]\nblitz_macos = { command = \"bridge\" }",
        "[mcp_servers.blitz_macos]\ncommand = \"\"",
        "[mcp_servers.blitz_macos.env]\nPATH = \"/bin\"",
        "[mcp_servers.blitz_macos]\ncommand = \"one\"\n[mcp_servers.blitz_macos]\ncommand = \"two\"",
    ]
    for text in cases {
        let result = MCPIntegrationConfiguration.inspect(agent: .codex, data: Data(text.utf8), file: URL(fileURLWithPath: "/tmp/config.toml"))
        #expect(result.app == .unreadable)
    }
}

@Test func mcpIntegrationSupportsCRLFAndQuotedTOMLServerKeys() {
    let text = "[mcp_servers.\"blitz_macos\"]\r\ncommand = '/Users/test/bridge'\r\n"
    let result = MCPIntegrationConfiguration.inspect(agent: .codex, data: Data(text.utf8), file: URL(fileURLWithPath: "/tmp/config.toml"))
    #expect(result.app == .present)
    #expect(result.iphone == .missing)
}

@Test func mcpIntegrationDistinguishesAbsentAndUnreadableJSONConfiguration() {
    let file = URL(fileURLWithPath: "/tmp/.claude.json")
    let absent = MCPIntegrationConfiguration.inspect(agent: .claudeCode, data: Data("{}".utf8), file: file)
    let invalid = MCPIntegrationConfiguration.inspect(agent: .claudeCode, data: Data("invalid".utf8), file: file)
    let existing = MCPIntegrationConfiguration.inspect(agent: .claudeCode, data: Data(#"{"mcpServers":{"blitz-macos":{"command":"bridge"}}}"#.utf8), file: file)
    #expect(absent.app == .missing)
    #expect(invalid.app == .unreadable)
    #expect(existing.app == .present)
    #expect(existing.iphone == .missing)
}

@Test func mcpManualConfigurationEscapesPathsWithoutInvalidTOMLSlashEscapes() throws {
    let path = "/Users/test \"quoted\"\\name/.blitz/blitz-macos-mcp"
    let claude = MCPIntegrationConfiguration.manualSnippet(agent: .claudeCode, helperPath: path)
    let object = try #require(JSONSerialization.jsonObject(with: Data(claude.utf8)) as? [String: [String: String]])
    #expect(object["blitz-macos"]?["command"] == path)
    let codex = MCPIntegrationConfiguration.manualSnippet(agent: .codex, helperPath: path)
    #expect(codex.hasPrefix("[mcp_servers.blitz_macos]\ncommand = "))
    #expect(!codex.contains("\\/"))
    let value = String(try #require(codex.components(separatedBy: "command = ").last))
    #expect(try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) as? String == path)
    #expect(!codex.contains("enabled_tools"))
    #expect(!codex.contains("approval"))
}

@Test func mcpConfigurationDiscoveryRespectsCustomClientRoots() {
    let home = URL(fileURLWithPath: "/Users/test")
    #expect(MCPIntegrationConfiguration.configurationFile(agent: .codex, home: home, environment: ["CODEX_HOME": "/tmp/codex-audit"]).path == "/tmp/codex-audit/config.toml")
    #expect(MCPIntegrationConfiguration.configurationFile(agent: .claudeCode, home: home, environment: [:]).path == "/Users/test/.claude.json")
    #expect(MCPIntegrationConfiguration.configurationFile(agent: .opencode, home: home, environment: ["XDG_CONFIG_HOME": "/tmp/config"]).path == "/tmp/config/opencode/opencode.json")
}

@Test func mcpConfigurationLoadLeavesExistingClientSettingsUnchanged() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let file = home.appendingPathComponent(".codex/config.toml")
    let original = Data("model = \"personal-model\"\n[mcp_servers.blitz_macos]\ncommand = \"bridge\"\nenabled = false\n".utf8)
    try original.write(to: file)
    let result = MCPIntegrationConfiguration.load(agent: .codex, home: home, environment: [:])
    #expect(result.app == .disabled)
    #expect(result.iphone == .missing)
    #expect(try Data(contentsOf: file) == original)
}
