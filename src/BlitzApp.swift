// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Darwin
import SwiftUI

final class BlitzAppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LogClear()
        Log("launch_log=\(BlitzPaths.launchLogFile.path)")
        AppRelaunchService.shared.clearPendingRestart()
        AnalyticsService.trackAppLaunch()
        if let fileMenu = NSApp.mainMenu?.item(withTitle: "Ablage")
            ?? NSApp.mainMenu?.item(withTitle: "File") {
            fileMenu.title = L10n.tr("Projekt")
        }
        // Set dock icon from bundled resource (needed for swift run / non-.app launches)
        if Bundle.main.bundleURL.pathExtension != "app",
           let icon = Bundle.appResources.image(forResource: "blitz-icon") {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppRelaunchService.shared.clearPendingRestartAfterReturningToApp()
        guard let appState else { return }
        Task { @MainActor in
            appState.ascManager.refreshAppIconStatusIfNeeded(for: appState.activeProjectId)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = AppRelaunchService.shared.schedulePendingScreenRecordingRelaunchIfNeeded()
        MCPBootstrap.shared.shutdown()
        appState?.gestureVisualization.tearDown()
        // Simulator processes are shared with Xcode and other tools. Leaving Blitz
        // must not shut down a device, even if Blitz originally started it.
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if appState?.activeProjectId != nil {
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    return false
                }
            }
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }
}

@main
struct BlitzApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: BlitzAppDelegate
    @State private var appState: AppState

    init() {
        if Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier {
            AppIdentity.migratePreferences()
        }
        _appState = State(initialValue: AppState())
    }

    var body: some Scene {
        Window("Blitz Neo", id: "main") {
            ContentView(appState: appState)
                .environment(\.locale, L10n.locale)
                .focusEffectDisabled()
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .defaultSize(width: 1200, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands(appState: appState)
        }
    }
}

/// Manages MCP server lifecycle independently of SwiftUI view callbacks.
@MainActor
final class MCPBootstrap {
    static let shared = MCPBootstrap()
    private(set) var server: MCPServerService?
    private var started = false

    func boot(appState: AppState) {
        guard !started else { return }
        started = true

        Self.installMCPHelper(from: bundledMCPHelperURL())
        installASCEnvironment(settings: appState.settingsStore)
        installClaudeSkills()
        ProjectStorage().ensureGlobalMCPConfigs(
            whitelistBlitzMCP: appState.settingsStore.whitelistBlitzMCPTools,
            allowASCCLICalls: appState.settingsStore.allowASCCLICalls
        )
        let whitelistBlitzMCP = appState.settingsStore.whitelistBlitzMCPTools
        let allowASCCLICalls = appState.settingsStore.allowASCCLICalls
        Task.detached(priority: .utility) {
            ProjectStorage().ensureAllProjectMCPConfigs(
                whitelistBlitzMCP: whitelistBlitzMCP,
                allowASCCLICalls: allowASCCLICalls
            )
        }

        let server = MCPServerService(appState: appState)
        self.server = server
        appState.mcpServer = server

        Task.detached {
            do {
                try await server.start()
            } catch {
                print("[MCP] Failed to start server: \(error)")
            }
        }
    }

    func shutdown() {
        guard let server else { return }
        // Fire-and-forget — app is terminating
        Task.detached { await server.stop() }
        // Brief wait to allow cleanup
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Copies bundled Claude skills to ~/.claude/skills/ so they're globally available.
    /// Overwrites on every launch to keep skills in sync with the app version.
    private func installClaudeSkills() {
        let fm = FileManager.default
        let destRoot = BlitzPaths.claudeSkills

        // Look for embedded skills in the app bundle
        guard let bundleSkills = Bundle.main.resourceURL?
        .appendingPathComponent("claude-skills") else { return }
        guard fm.fileExists(atPath: bundleSkills.path) else { return }

        do {
            try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
            let skills = try fm.contentsOfDirectory(atPath: bundleSkills.path)
            for skill in skills {
                let src = bundleSkills.appendingPathComponent(skill)
                let dst = destRoot.appendingPathComponent(skill)
                // Remove old version and copy fresh
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
        } catch {
            print("[MCP] Failed to install Claude skills: \(error)")
        }
    }

    nonisolated static func installMCPHelper(
        from sourceURL: URL?,
        helper: URL = BlitzPaths.mcpHelper,
        bridge: URL = BlitzPaths.mcpBridge,
        cli: URL = BlitzPaths.bin.appendingPathComponent("blitz-neo")
    ) {
        let fm = FileManager.default
        if let source = sourceURL?.resolvingSymlinksInPath() {
            installExecutable(at: helper, matches: fm.contentsEqual(atPath: source.path, andPath: helper.path)) {
                try fm.copyItem(at: source, to: $0)
            }
        } else {
            print("[MCP] Failed to locate bundled blitz-macos-mcp helper")
        }

        // Keep the old script path working for manually created configs while
        // new project configs point directly at the helper executable.
        let bridgeScript = """
                           #!/bin/bash
                           HELPER="$HOME/.blitz/blitz-macos-mcp"
                           if [ ! -x "$HELPER" ]; then
                               echo '{"jsonrpc":"2.0","id":null,"error":{"code":-1,"message":"Blitz Neo MCP helper is not installed. Start Blitz Neo first."}}' >&2
                               exit 1
                           fi
                           exec "$HELPER" "$@"
                           """
        let launcher = Data(bridgeScript.utf8)
        for destination in [bridge, cli] {
            installExecutable(at: destination, matches: (try? Data(contentsOf: destination)) == launcher) {
                try launcher.write(to: $0, options: .withoutOverwriting)
            }
        }
    }

    private nonisolated static func installExecutable(
        at destination: URL, matches: @autoclosure () -> Bool, stage: (URL) throws -> Void
    ) {
        let fm = FileManager.default
        let attributes = try? fm.attributesOfItem(atPath: destination.path)
        if attributes?[.type] as? FileAttributeType == .typeRegular,
           attributes?[.posixPermissions] as? Int == 0o755, matches() { return }

        do {
            let directory = destination.deletingLastPathComponent()
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let staged = directory.appendingPathComponent(".blitz-executable-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staged) }
            try stage(staged)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            // Concurrent callers can execute the old or new file throughout startup.
            guard Darwin.rename(staged.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            print("[MCP] Failed to install \(destination.lastPathComponent): \(error)")
        }
    }

    private func installASCEnvironment(settings: SettingsService) {
        try? ASCAuthBridge().installCLIShims()
        try? ShellIntegrationService().sync(enabled: settings.enableASCShellIntegration)
    }

    private func bundledMCPHelperURL() -> URL? {
        let fm = FileManager.default

        let bundledHelper = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/blitz-macos-mcp")
        if fm.isExecutableFile(atPath: bundledHelper.path) {
            return bundledHelper
        }

        if let executableURL = Bundle.main.executableURL {
            let siblingHelper = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("blitz-macos-mcp")
            if fm.isExecutableFile(atPath: siblingHelper.path) {
                return siblingHelper
            }
        }

        return nil
    }
}
