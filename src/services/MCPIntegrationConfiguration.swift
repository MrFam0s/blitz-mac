// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// Read-only discovery of user-level client configuration. It never installs a
/// server or changes a client's tool selection or approval settings.
struct MCPIntegrationConfiguration {
    enum State: Equatable {
        case missing, present, disabled, restricted, unreadable

        var label: String {
            switch self {
            case .missing: return L10n.tr("Kein globaler Eintrag")
            case .present: return L10n.tr("Globaler Eintrag vorhanden")
            case .disabled: return L10n.tr("Global deaktiviert")
            case .restricted: return L10n.tr("Global mit Werkzeugauswahl")
            case .unreadable: return L10n.tr("Nicht prüfbar")
            }
        }
    }

    let file: URL
    let app: State
    let iphone: State

    static func load(agent: AIAgent, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        var file = configurationFile(agent: agent, home: home, environment: environment)
        if agent == .opencode, !FileManager.default.fileExists(atPath: file.path) {
            let jsonc = file.deletingPathExtension().appendingPathExtension("jsonc")
            if FileManager.default.fileExists(atPath: jsonc.path) { file = jsonc }
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            return Self(file: file, app: .missing, iphone: .missing)
        }
        guard let data = try? Data(contentsOf: file) else {
            return Self(file: file, app: .unreadable, iphone: .unreadable)
        }
        return inspect(agent: agent, data: data, file: file)
    }

    static func configurationFile(agent: AIAgent, home: URL, environment: [String: String]) -> URL {
        switch agent {
        case .codex:
            let root = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            return root.appendingPathComponent("config.toml")
        case .claudeCode:
            if let root = environment["CLAUDE_CONFIG_DIR"], !root.isEmpty {
                return URL(fileURLWithPath: root).appendingPathComponent(".claude.json")
            }
            return home.appendingPathComponent(".claude.json")
        case .opencode:
            if let path = environment["OPENCODE_CONFIG"], !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            let root = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".config")
            return root.appendingPathComponent("opencode/opencode.json")
        }
    }

    static func inspect(agent: AIAgent, data: Data, file: URL) -> Self {
        if agent == .codex {
            guard let text = String(data: data, encoding: .utf8) else {
                return Self(file: file, app: .unreadable, iphone: .unreadable)
            }
            return Self(file: file, app: codexState(text, name: "blitz_macos"),
                        iphone: codexState(text, name: "blitz-iphone"))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self(file: file, app: .unreadable, iphone: .unreadable)
        }
        let key = agent == .opencode ? "mcp" : "mcpServers"
        if root[key] != nil, root[key] as? [String: Any] == nil {
            return Self(file: file, app: .unreadable, iphone: .unreadable)
        }
        let servers = root[key] as? [String: Any] ?? [:]
        func state(_ name: String) -> State {
            guard let server = servers[name] as? [String: Any] else { return .missing }
            if server["enabled"] as? Bool == false || server["disabled"] as? Bool == true { return .disabled }
            guard server["command"] != nil || server["url"] != nil else { return .unreadable }
            return .present
        }
        return Self(file: file, app: state("blitz-macos"), iphone: state("blitz-iphone"))
    }

    private static func codexState(_ text: String, name: String) -> State {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        // This is deliberately not a TOML parser. Unusual syntax is left to the
        // client rather than treating a string's example table as configuration.
        guard !text.contains("\"\"\""), !text.contains("'''"), !text.contains("\u{0000}") else { return .unreadable }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let header = "(?m)^[ \\t]*\\[[ \\t]*mcp_servers[ \\t]*\\.[ \\t]*(?:\(escaped)|\"\(escaped)\"|'\(escaped)')[ \\t]*\\][ \\t]*(?:#[^\\r\\n]*)?$"
        guard let expression = try? NSRegularExpression(pattern: header) else { return .unreadable }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count <= 1 else { return .unreadable }
        guard let match = matches.first, let range = Range(match.range, in: text) else {
            let uncommentedLines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            // Inline tables, dotted assignments and nested tables can define a
            // server too. Do not offer a duplicate entry when discovery is unsure.
            return uncommentedLines.contains(where: { $0.contains(name) }) ? .unreadable : .missing
        }
        let remainder = String(text[range.upperBound...])
        let nextTable = remainder.range(of: "(?m)^[ \\t]*\\[", options: .regularExpression)
        let body = nextTable.map { String(remainder[..<$0.lowerBound]) } ?? remainder
        if body.range(of: "(?m)^[ \\t]*enabled[ \\t]*=[ \\t]*false[ \\t]*(?:#[^\\r\\n]*)?$", options: .regularExpression) != nil {
            return .disabled
        }
        let endpoint = #"(?m)^[ \t]*(?:command|url)[ \t]*=[ \t]*(?:"(?:[^"\\\r\n]|\\.)+"|'[^'\r\n]+')[ \t]*(?:#[^\r\n]*)?$"#
        guard body.range(of: endpoint, options: .regularExpression) != nil else { return .unreadable }
        if body.range(of: "(?m)^[ \\t]*(?:enabled_tools|disabled_tools)[ \\t]*=", options: .regularExpression) != nil {
            return .restricted
        }
        return .present
    }

    /// Phone/simulator integration has separate runtime requirements and is
    /// already managed for Blitz projects; this describes only the app bridge.
    static func manualSnippet(agent: AIAgent, helperPath: String) -> String {
        switch agent {
        case .codex:
            return "[mcp_servers.blitz_macos]\ncommand = \(jsonString(helperPath))"
        case .claudeCode:
            return json(["blitz-macos": ["command": helperPath]])
        case .opencode:
            return json(["blitz-macos": ["type": "local", "command": [helperPath], "enabled": true]])
        }
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private static func jsonString(_ value: String) -> String { json(value) }
}
