import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.blitz.macos", category: "SimulatorService")

/// High-level simulator management service
actor SimulatorService: SimulatorDeviceService {
    private let simctl = SimctlClient()

    /// List all available simulators
    func listDevices() async throws -> [SimctlClient.SimctlDevice] {
        try await simctl.listDevices()
    }

    /// Start only the requested device, preserving all other simulator sessions.
    func boot(udid: String) async throws {
        try await bootInBackground(udid: udid)
    }

    func bootInBackground(udid: String) async throws {
        do {
            try await simctl.boot(udid: udid)
        } catch {
            if let processError = error as? ProcessRunner.ProcessError,
               processError.stderr.contains("current state: Booted") {
                // It may have been booted by Xcode since our last inventory.
            } else {
                throw error
            }
        }
        for _ in 0..<30 {
            try Task.checkCancellation()
            if try await simctl.listDevices().contains(where: { $0.udid == udid && $0.isBooted }) {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw NSError(domain: "BlitzSimulator", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the selected simulator to start."])
    }

    /// Shutdown a simulator
    func shutdown(udid: String) async throws {
        try await simctl.shutdown(udid: udid)
    }

    /// Install an app bundle
    func installApp(udid: String, appPath: String) async throws {
        try await simctl.install(udid: udid, appPath: appPath)
    }

    /// Launch an app by bundle ID
    func launchApp(udid: String, bundleId: String) async throws {
        try await simctl.launch(udid: udid, bundleId: bundleId)
    }

    /// Take a screenshot and save to path
    func screenshot(udid: String, saveTo path: String) async throws {
        try await simctl.screenshot(udid: udid, path: path)
    }

    /// Open the Simulator.app (-g flag opens in background)
    func openSimulatorApp(udid: String) async throws {
        let developerDirectory: String
        if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !override.isEmpty {
            developerDirectory = override
        } else {
            developerDirectory = try await ProcessRunner.run("/usr/bin/xcode-select", arguments: ["-p"])
        }
        let application = try SimulatorApplication.resolve(developerDirectory: developerDirectory)
        _ = try await ProcessRunner.run("/usr/bin/open", arguments: application.openArguments(udid: udid))
        try await Task.sleep(for: .milliseconds(500))
    }

    /// Move Simulator.app's window to the same position as Blitz's window
    /// using the Accessibility API, so it's completely hidden behind Blitz.
    private static func moveSimulatorWindowBehind(blitzFrame: NSRect) {
        guard let simApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.iphonesimulator"
        ).first else { return }

        let appRef = AXUIElementCreateApplication(simApp.processIdentifier)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let simWindow = windows.first else { return }

        // Accessibility uses top-left origin; NSRect uses bottom-left
        let screenHeight = NSScreen.main?.frame.height ?? 0
        var position = CGPoint(
            x: blitzFrame.origin.x,
            y: screenHeight - blitzFrame.origin.y - blitzFrame.height
        )
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(simWindow, kAXPositionAttribute as CFString, posValue)
        }

        var size = CGSize(width: blitzFrame.width, height: blitzFrame.height)
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(simWindow, kAXSizeAttribute as CFString, sizeValue)
        }
    }
}
