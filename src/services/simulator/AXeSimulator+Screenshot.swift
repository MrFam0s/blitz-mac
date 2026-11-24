// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension AXeSimulator {
    func supportedScreenshotExecutable() async -> String? {
        await supportedExecutable(for: ["screenshot"], requiring: ["--screen-id", "--screen-uuid", "--expected-boot", "--verbose"],
                                  helpFlag: "--help-hidden")
    }

    private struct Inventory: Decodable {
        struct Screen: Decodable {
            let id: Int
            let uuid: UUID
            let role: String
            let width: Double
            let height: Double
            let scale: Double
            let rotation: Int
        }
        let udid: UUID
        let activeScreen: Screen
    }

    private struct BootInventory: Decodable {
        struct Panel: Decodable {
            struct Identity: Decodable {
                let displayID: Int
                let uniqueID: UUID
            }
            let identity: Identity
        }
        let requestedSimulatorUDID: UUID
        let activePanel: Panel
        let bootIdentity: String
    }

    private struct CaptureReceipt: Decodable {
        struct Context: Decodable {
            struct Observation: Decodable, Equatable {
                let simulatorUDID: UUID
                let screenID: Int
                let screenUniqueID: UUID
                let bootIdentity: String
                let rotation: Int
                let scale: Double
                let poseRevision: String?
            }
            let observation: Observation
        }
        let before: Context
        let after: Context
        let width: Int
        let height: Int
    }

    private struct Result<Payload: Decodable>: Decodable { let result: Payload }

    /// The user's export uses AXe's selected-panel capture. Continuous preview
    /// frames and input do not spawn this sequence of measurement processes.
    func captureActiveDuoPNG(udid: String, using path: String) async throws -> Data {
        func result<T: Decodable>(_ args: [String], command: String) async throws -> T {
            let text = try await runJSON(path, arguments: args)
            guard let response = try? JSONDecoder().decode(Response<Result<T>>.self, from: Data(text.utf8)),
                  !response.didError, response.command == command else { throw SimulatorScreen.ScreenError.ambiguous }
            return response.data.result
        }

        let inventory: Inventory = try await result(["displays", "--udid", udid], command: "displays")
        let screen = inventory.activeScreen
        guard inventory.udid == UUID(uuidString: udid), ["inner", "outer"].contains(screen.role),
              screen.width > 0, screen.height > 0, screen.scale > 0 else { throw SimulatorScreen.ScreenError.ambiguous }
        let boot: BootInventory = try await result(["displays", "--udid", udid, "--verbose"], command: "displays")
        guard boot.requestedSimulatorUDID == inventory.udid, boot.activePanel.identity.displayID == screen.id,
              boot.activePanel.identity.uniqueID == screen.uuid, !boot.bootIdentity.isEmpty else { throw SimulatorScreen.ScreenError.changed }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        let receipt: CaptureReceipt = try await result([
            "screenshot", "--udid", udid, "--screen-id", String(screen.id), "--screen-uuid", screen.uuid.uuidString,
            "--expected-boot", boot.bootIdentity, "--output", temporary.path, "--verbose"
        ], command: "screenshot")
        try Task.checkCancellation()
        let observation = receipt.before.observation
        guard observation == receipt.after.observation, observation.simulatorUDID == inventory.udid,
              observation.screenID == screen.id, observation.screenUniqueID == screen.uuid,
              observation.bootIdentity == boot.bootIdentity, observation.rotation == screen.rotation,
              observation.scale == screen.scale, Double(receipt.width) == screen.width * screen.scale,
              Double(receipt.height) == screen.height * screen.scale else { throw SimulatorScreen.ScreenError.changed }

        let png = try Data(contentsOf: temporary, options: .mappedIfSafe)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == receipt.width,
              properties[kCGImagePropertyPixelHeight] as? Int == receipt.height else { throw SimulatorScreen.ScreenError.changed }
        return png
    }
}
