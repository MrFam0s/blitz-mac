import Foundation

/// Per-device simulator display configuration.
/// Loaded from simulator-config.json (shared with blitz-cn).
struct SimulatorDeviceConfig: Codable {
    let toolbarHeight: Double
    let toolbarOffset: Double
    let widthPoints: Double
    let heightPoints: Double
    /// Left/right bezel width — measured at the canvas/frame display scale.
    /// "Snapshot the canvas, open in Figma, measure screen edge to frame edge, divide by 2."
    let borderX: Double
    /// Top/bottom bezel height — same measurement method.
    let borderY: Double

    enum CodingKeys: String, CodingKey {
        case toolbarHeight
        case toolbarOffset
        case widthPoints = "width_points"
        case heightPoints = "height_points"
        case borderX
        case borderY
    }
}

/// Lookup simulator config by device name and coordinate transformations.
/// Matches blitz-cn's simulator-config.ts approach:
///   - Crop only removes the toolbar; bezels remain visible
///   - Coordinate mapping explicitly subtracts bezels (not baked into crop)
struct SimulatorConfigDatabase {
    // MARK: - Config loading from JSON

    private struct ConfigFile: Codable {
        let devices: [String: SimulatorDeviceConfig]
    }

    private static let devices: [String: SimulatorDeviceConfig] = {
        guard let url = Bundle.appResources.url(forResource: "simulator-config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else { return [:] }
        return file.devices
    }()

    /// Only the classic Simulator window needs model-specific bezel calibration.
    static func legacyConfig(for deviceName: String, isCustomName: Bool = false) -> SimulatorDeviceConfig? {
        if let exact = devices[deviceName] { return exact }
        // Older inventories can omit deviceTypeIdentifier. Keep a project's
        // custom prefix, but never calibrate an unknown model as its predecessor.
        guard isCustomName else { return nil }
        let model = devices.keys.filter { deviceName.hasSuffix(" " + $0) }.max { $0.count < $1.count }
        return model.flatMap { devices[$0] }
    }

    // MARK: - Crop rect (toolbar-only crop, matches blitz-cn)

    /// Crop rect in UV space. Removes only the toolbar; bezels stay visible.
    /// The Metal view displays bezels + screen, matching blitz-cn's canvas approach.
    static func cropRect(config: SimulatorDeviceConfig, frameWidth: Int, frameHeight: Int) -> (x: Double, y: Double, w: Double, h: Double) {
        let fh = Double(frameHeight)
        let scale = 2.0
        let toolbarPx = (config.toolbarHeight + config.toolbarOffset) * scale

        return (
            x: 0,
            y: toolbarPx / fh,
            w: 1.0,
            h: (fh - toolbarPx) / fh
        )
    }

    // MARK: - Coordinate conversion (matches blitz-cn's canvasToSimulatorCoords)

    /// Convert view coordinates to simulator device points.
    ///
    /// The view displays the full frame minus toolbar (bezels + screen).
    /// This function subtracts the bezel to map into the screen area,
    /// matching blitz-cn's `canvasToSimulatorCoords` formula.
    ///
    /// - Parameters:
    ///   - viewX/viewY: touch position in the SwiftUI overlay view
    ///   - viewWidth/viewHeight: overlay view dimensions
    ///   - config: device config with borderX/borderY
    ///   - frameWidth/frameHeight: captured frame dimensions in pixels
    static func viewToSimulatorCoords(
        viewX: Double, viewY: Double,
        viewWidth: Double, viewHeight: Double,
        config: SimulatorDeviceConfig,
        frameWidth: Int, frameHeight: Int
    ) -> (x: Double, y: Double) {
        let scale = 2.0
        let fw = Double(frameWidth)
        let fh = Double(frameHeight)
        let toolbarPx = (config.toolbarHeight + config.toolbarOffset) * scale

        // Crop height (what the view shows = frame minus toolbar)
        let cropW = fw
        let cropH = fh - toolbarPx

        // Bezel as a fraction of the crop region
        let bxFrac = (config.borderX * scale) / cropW
        let byFrac = (config.borderY * scale) / cropH

        // Normalized position in the view (0–1)
        let vx = viewX / viewWidth
        let vy = viewY / viewHeight

        // Subtract bezel, scale to screen area, multiply by device points
        let simX = ((vx - bxFrac) / (1 - 2 * bxFrac)) * config.widthPoints
        let simY = ((vy - byFrac) / (1 - 2 * byFrac)) * config.heightPoints

        return (x: simX, y: simY)
    }

    /// Inverse: convert simulator device points to view coordinates.
    static func simulatorToViewCoords(
        simX: Double, simY: Double,
        viewWidth: Double, viewHeight: Double,
        config: SimulatorDeviceConfig,
        frameWidth: Int, frameHeight: Int
    ) -> (x: Double, y: Double) {
        let scale = 2.0
        let fw = Double(frameWidth)
        let fh = Double(frameHeight)
        let toolbarPx = (config.toolbarHeight + config.toolbarOffset) * scale

        let cropW = fw
        let cropH = fh - toolbarPx

        let bxFrac = (config.borderX * scale) / cropW
        let byFrac = (config.borderY * scale) / cropH

        let vx = (simX / config.widthPoints) * (1 - 2 * bxFrac) + bxFrac
        let vy = (simY / config.heightPoints) * (1 - 2 * byFrac) + byFrac

        return (x: vx * viewWidth, y: vy * viewHeight)
    }
}

struct SimulatorInfo: Identifiable, Hashable {
    let udid: String
    let name: String
    let state: String
    let deviceTypeIdentifier: String?
    let lastBootedAt: String?

    var id: String { udid }
    var isBooted: Bool { state == "Booted" }

    var legacyConfig: SimulatorDeviceConfig? {
        SimulatorConfigDatabase.legacyConfig(for: displayName, isCustomName: deviceTypeIdentifier == nil)
    }

    var supportsAppInteraction: Bool {
        // Project simulator names are editable. Read the underlying device family.
        let model = displayName
        return model == "iPhone" || model.hasPrefix("iPhone ") ||
               model == "iPad" || model.hasPrefix("iPad ") ||
               (deviceTypeIdentifier == nil && legacyConfig != nil)
    }

    var displayName: String {
        // Extract device type from identifier like "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
        if let typeId = deviceTypeIdentifier {
            let components = typeId.split(separator: ".")
            if let last = components.last {
                return String(last).replacingOccurrences(of: "-", with: " ")
            }
        }
        return name
    }
}
