import Foundation

/// Locate the viewer in the selected Xcode, including Xcode 27's Device Hub.
struct SimulatorApplication: Equatable {
    enum Kind { case simulator, deviceHub }
    let url: URL
    let kind: Kind

    static func resolve(developerDirectory: String, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) throws -> Self {
        let path = developerDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw LaunchError.viewerUnavailable }
        let selected = URL(fileURLWithPath: path)
        let developer = selected.pathExtension == "app"
            ? selected.appendingPathComponent("Contents/Developer") : selected
        let candidates: [Self] = [
            .init(url: developer.deletingLastPathComponent().appendingPathComponent("Applications/DeviceHub.app"), kind: .deviceHub),
            .init(url: developer.appendingPathComponent("Applications/Simulator.app"), kind: .simulator),
            .init(url: developer.deletingLastPathComponent().appendingPathComponent("Applications/Simulator.app"), kind: .simulator)
        ]
        guard let application = candidates.first(where: { exists($0.url.path) }) else {
            throw LaunchError.viewerUnavailable
        }
        return application
    }

    func openArguments(udid: String) throws -> [String] {
        guard let id = UUID(uuidString: udid) else { throw LaunchError.invalidDevice }
        switch kind {
        case .simulator:
            return ["-g", "-a", url.path, "--args", "-CurrentDeviceUDID", id.uuidString]
        case .deviceHub:
            // Device Hub's registered devices URL handler opens a compact device window.
            var destination = URLComponents()
            destination.scheme = "devices"
            destination.host = ""
            destination.path = "/device/open"
            destination.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
            guard let target = destination.url else { throw LaunchError.invalidDevice }
            return ["-g", "-a", url.path, target.absoluteString]
        }
    }

    enum LaunchError: LocalizedError {
        case viewerUnavailable, invalidDevice
        var errorDescription: String? {
            switch self {
            case .viewerUnavailable:
                "Device Hub or Simulator could not be found in the selected Xcode. Check Xcode's command-line tools selection."
            case .invalidDevice:
                "The selected simulator has an invalid identifier. Refresh the devices and choose it again."
            }
        }
    }
}
