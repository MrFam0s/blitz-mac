// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// Inspects only Blitz-managed files. A tool being installed does not imply
/// that a user's external shell resolves its short command through PATH.
struct TerminalToolInstallation: Identifiable, Equatable {
    enum Tool: String, CaseIterable {
        case asc
        case release = "blitz-neo"

        var title: String {
            switch self {
            case .asc: return "ASC"
            case .release: return "Blitz Neo CLI"
            }
        }

        var detail: String {
            switch self {
            case .asc: return "Store-Daten, Builds und Uploads mit derselben ASC-Installation wie in Blitz Neo."
            case .release: return "Updates aus anderen Chats prüfen und über den Blitz-Neo-Ablauf einreichen. Blitz Neo muss dafür geöffnet sein."
            }
        }
    }

    enum Availability: Equatable {
        case installed
        case incomplete
        case missing
    }

    let tool: Tool
    let executableURL: URL
    let availability: Availability

    var id: String { tool.rawValue }

    /// Always copy an absolute, quoted command. It remains valid even when
    /// Blitz's optional shell block is disabled or another ASC is on PATH.
    var shellCommand: String {
        "'" + executableURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func inspect(
        blitzRoot: URL = BlitzPaths.root,
        fileManager: FileManager = .default
    ) -> [TerminalToolInstallation] {
        Tool.allCases.map { tool in
            let executable = blitzRoot.appendingPathComponent("bin/\(tool.rawValue)")
            let helper = blitzRoot.appendingPathComponent(
                tool == .asc ? "bin/ascd" : "blitz-macos-mcp"
            )
            let wrapperReady = isExecutableFile(executable, fileManager: fileManager)
            let helperReady = isExecutableFile(helper, fileManager: fileManager)
            let availability: Availability
            if wrapperReady && helperReady {
                availability = .installed
            } else if fileManager.fileExists(atPath: executable.path)
                        || fileManager.fileExists(atPath: helper.path) {
                availability = .incomplete
            } else {
                availability = .missing
            }
            return TerminalToolInstallation(tool: tool, executableURL: executable, availability: availability)
        }
    }

    private static func isExecutableFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: url.path)
    }
}

enum TerminalShellShortcutState: Equatable {
    case unconfigured
    case configured
    case incomplete

    static func inspect(
        enabled: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        blitzRoot: URL = BlitzPaths.root,
        fileManager: FileManager = .default
    ) -> Self {
        func hasBlock(in name: String) -> Bool {
            guard let text = try? String(contentsOf: homeDirectory.appendingPathComponent(name), encoding: .utf8),
                  let start = text.range(of: "# >>> Blitz shell integration >>>") else { return false }
            return text.range(of: "# <<< Blitz shell integration <<<", range: start.upperBound..<text.endIndex) != nil
        }
        let hasAnyBlock = [".zshrc", ".bashrc"].contains { hasBlock(in: $0) }
        let activeRCName = ShellIntegrationService().targetRCFile?.lastPathComponent
        let activeBlock = activeRCName.map { hasBlock(in: $0) } ?? false
        let initPath = blitzRoot.appendingPathComponent("shell/init.sh").path
        var isDirectory: ObjCBool = false
        let hasInit = fileManager.fileExists(atPath: initPath, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isReadableFile(atPath: initPath)
        if enabled && activeBlock && hasInit { return .configured }
        if enabled || hasAnyBlock || fileManager.fileExists(atPath: initPath) { return .incomplete }
        return .unconfigured
    }
}
