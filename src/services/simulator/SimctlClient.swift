import Foundation
import ImageIO

/// Parses `xcrun simctl list devices -j` output
struct SimctlClient: Sendable {

    init() {}

    struct DeviceList: Codable, Sendable {
        let devices: [String: [SimctlDevice]]
    }

    struct SimctlDevice: Codable, Sendable, Identifiable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool
        let deviceTypeIdentifier: String?
        let lastBootedAt: String?

        var id: String { udid }
        var isBooted: Bool { state == "Booted" }
    }

    /// Parse the JSON output of `xcrun simctl list devices -j`
    func parseDeviceList(json: Data) throws -> [SimctlDevice] {
        let decoded = try JSONDecoder().decode(DeviceList.self, from: json)
        return decoded.devices.values
            .flatMap { $0 }
            .filter { $0.isAvailable }
            .sorted { ($0.name) < ($1.name) }
    }

    /// List all available simulators
    func listDevices() async throws -> [SimctlDevice] {
        let result = try await ProcessRunner.run("xcrun", arguments: ["simctl", "list", "devices", "-j"])
        return try parseDeviceList(json: Data(result.utf8))
    }

    /// Boot a simulator
    func boot(udid: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: ["simctl", "boot", udid])
    }

    /// Shutdown a simulator
    func shutdown(udid: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: ["simctl", "shutdown", udid])
    }

    /// Install an app bundle
    func install(udid: String, appPath: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: ["simctl", "install", udid, appPath])
    }

    /// Launch an app by bundle ID
    func launch(udid: String, bundleId: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: ["simctl", "launch", udid, bundleId])
    }

    func integratedScreens(udid: String) async throws -> [SimulatorScreen] {
        let output = try await ProcessRunner.run("xcrun", arguments: ["simctl", "io", udid, "enumerate"])
        return SimulatorScreen.integratedScreens(in: output)
    }

    func activeScreenSize(udid: String, accessibility: IDBClient) async throws -> CGSize {
        let screens = try await integratedScreens(udid: udid)
        if screens.count == 1 { return screens[0].points }
        guard !screens.isEmpty else { throw SimulatorScreen.ScreenError.ambiguous }
        let size = try await accessibility.applicationScreenSize(udid: udid)
        return try SimulatorScreen.active(in: screens, applicationSize: size).points
    }

    func activeTouchSize(udid: String, accessibility: IDBClient) async throws -> CGSize {
        let screens = try await integratedScreens(udid: udid)
        if screens.count == 1, let points = screens[0].orientedPoints { return points }
        let root = try await accessibility.applicationScreenSize(udid: udid)
        let active = try SimulatorScreen.active(in: screens, applicationSize: root)
        guard let points = active.orientedPoints else { throw SimulatorScreen.ScreenError.ambiguous }
        return points
    }

    /// Capture a flat native framebuffer; never derive device input coordinates from a 3D bezel.
    func captureActiveScreen(
        udid: String, accessibility: IDBClient, screens: [SimulatorScreen]? = nil
    ) async throws -> (image: CGImage, points: CGSize) {
        // A conventional device has one physical touch surface. App accessibility
        // frames can be inset, or absent entirely when the test app has exited.
        if let screens, screens.count == 1, let screen = screens.first {
            let data = try await framebufferPNG(udid: udid, screen: screen)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SimulatorScreen.ScreenError.changed }
            let points = CGSize(width: CGFloat(image.width) / screen.scale, height: CGFloat(image.height) / screen.scale)
            guard points == screen.points || points == CGSize(width: screen.points.height, height: screen.points.width) else {
                throw SimulatorScreen.ScreenError.changed
            }
            return (image, points)
        }
        let descriptors: [SimulatorScreen]
        if let screens { descriptors = screens } else { descriptors = try await integratedScreens(udid: udid) }
        let capture = try await activePNG(udid: udid, accessibility: accessibility, screens: descriptors)
        guard let source = CGImageSourceCreateWithData(capture.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw SimulatorScreen.ScreenError.changed }
        return (image, capture.points)
    }

    private func framebufferPNG(udid: String, screen: SimulatorScreen) async throws -> Data {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await ProcessRunner.run("xcrun", arguments: ["simctl", "io", udid, "screenshot", "--display=" + screen.id, temporary.path])
        try Task.checkCancellation()
        return try Data(contentsOf: temporary, options: .mappedIfSafe)
    }

    private func activePNG(
        udid: String, accessibility: IDBClient, screens: [SimulatorScreen]
    ) async throws -> (data: Data, points: CGSize) {
        let before = try await accessibility.applicationScreenSize(udid: udid)
        let screen = try SimulatorScreen.active(in: screens, applicationSize: before)
        let data = try await framebufferPNG(udid: udid, screen: screen)
        let after = try await accessibility.applicationScreenSize(udid: udid)
        guard after == before else { throw SimulatorScreen.ScreenError.changed }
        // IDB can describe the landscape inner display with a portrait root.
        // Read the current orientation again, even when topology was cached.
        let current = try await integratedScreens(udid: udid)
        let active = try SimulatorScreen.active(in: current, applicationSize: after)
        guard active.id == screen.id, let points = active.orientedPoints else { throw SimulatorScreen.ScreenError.changed }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              CGFloat(width) == points.width * active.scale,
              CGFloat(height) == points.height * active.scale
        else { throw SimulatorScreen.ScreenError.changed }
        return (data, points)
    }

    func screenshot(udid: String, path: String) async throws {
        let axe = AXeSimulator()
        if !axe.candidates.isEmpty,
           let devices = try? await listDevices(),
           devices.contains(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame && $0.deviceTypeIdentifier == SimulatorPose.deviceType }),
           let executable = await axe.supportedScreenshotExecutable() {
            let png = try await axe.captureActiveDuoPNG(udid: udid, using: executable)
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            return
        }
        let screens = try await integratedScreens(udid: udid)
        if screens.count <= 1 {
            // Older Xcodes lack connected-screen descriptors. Keep their default
            // for conventional simulators; simctl itself rejects ambiguous targets.
            var arguments = ["simctl", "io", udid, "screenshot"]
            if let screen = screens.first { arguments.append("--display=" + screen.id) }
            try await ProcessRunner.run("xcrun", arguments: arguments + [path])
            return
        }
        let accessibility = IDBClient()
        do {
            let capture = try await activePNG(udid: udid, accessibility: accessibility, screens: screens)
            try capture.data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            await accessibility.shutdown()
            throw error
        }
        await accessibility.shutdown()
    }

    /// Send a tap event
    func tap(udid: String, x: Double, y: Double) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: [
            "simctl", "io", udid, "tap", "\(Int(x))", "\(Int(y))"
        ])
    }

    /// Send a swipe event
    func swipe(udid: String, fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double = 0.3) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: [
            "simctl", "io", udid, "swipe",
            "\(Int(fromX))", "\(Int(fromY))",
            "\(Int(toX))", "\(Int(toY))",
            "--duration", "\(duration)"
        ])
    }

    /// Send a button press
    func pressButton(udid: String, button: String) async throws {
        // Map button names to simctl commands
        switch button.lowercased() {
        case "home":
            _ = try await ProcessRunner.run("xcrun", arguments: [
                "simctl", "io", udid, "sendkey", "home"
            ])
        case "lock", "side_button":
            _ = try await ProcessRunner.run("xcrun", arguments: [
                "simctl", "io", udid, "sendkey", "lock"
            ])
        default:
            _ = try await ProcessRunner.run("xcrun", arguments: [
                "simctl", "io", udid, "sendkey", button
            ])
        }
    }

    /// Input text into the simulator
    func inputText(udid: String, text: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: [
            "simctl", "io", udid, "input-text", text
        ])
    }

    /// Open a URL in the simulator
    func openURL(udid: String, url: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: [
            "simctl", "openurl", udid, url
        ])
    }
}
