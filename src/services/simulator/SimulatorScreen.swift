// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// A built-in screen from the DisplayAdapter's connected-screen descriptors.
struct SimulatorScreen: Equatable {
    let id: String
    let points: CGSize
    let scale: CGFloat
    let orientation: String?

    var orientedPoints: CGSize? {
        let landscape: Bool
        switch orientation {
        case "Landscape Left", "Landscape Right": landscape = true
        case "Portrait", "Portrait Upside Down": landscape = false
        default: return nil
        }
        return (points.width > points.height) == landscape ? points : CGSize(width: points.height, height: points.width)
    }

    static func integratedScreens(in inventory: String) -> [Self] {
        var fields: [String: String] = [:]
        var screens: [Self] = []
        func finish() {
            defer { fields.removeAll(keepingCapacity: true) }
            guard fields["Screen Type"] == "Integrated",
                  let id = fields["Screen ID"], Int(id) != nil,
                  let pixels = fields["Pixel Size"],
                  let scale = fields["Preferred UI Scale"].flatMap(Double.init),
                  scale.isFinite, scale > 0 else { return }
            let size = NSSizeFromString(pixels)
            guard size.width > 0, size.height > 0 else { return }
            screens.append(Self(id: id, points: CGSize(width: size.width / scale, height: size.height / scale), scale: scale, orientation: fields["UI Orientation"]))
        }
        for line in inventory.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if key == "Screen ID" || key == "Port" { finish() }
            if key == "Screen ID" || fields["Screen ID"] != nil {
                fields[key] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        finish()
        return screens
    }

    /// simctl can report both Duo framebuffers as powered. The full-screen AX
    /// application frame identifies the actual touch surface, including rotation.
    static func active(in screens: [Self], applicationSize: CGSize) throws -> Self {
        let matches = screens.filter {
            $0.points == applicationSize || ($0.points.width == applicationSize.height && $0.points.height == applicationSize.width)
        }
        guard matches.count == 1 else { throw ScreenError.ambiguous }
        return matches[0]
    }

    static func applicationSize(from data: Data) throws -> CGSize {
        struct Element: Decodable {
            struct Frame: Decodable { let x, y, width, height: CGFloat }
            let type: String?
            let frame: Frame?
        }
        let roots = try JSONDecoder().decode([Element].self, from: data)
        let frames = roots.filter { $0.type == "Application" }.compactMap(\.frame)
        guard let first = frames.first, first.width > 0, first.height > 0,
              frames.allSatisfy({ $0.x == 0 && $0.y == 0 && $0.width == first.width && $0.height == first.height })
        else { throw ScreenError.ambiguous }
        return CGSize(width: first.width, height: first.height)
    }

    enum ScreenError: LocalizedError {
        case ambiguous, changed
        var errorDescription: String? {
            switch self {
            case .ambiguous: L10n.tr("Das aktive Simulator-Display ist noch nicht eindeutig. Öffne die App im Simulator und versuche es erneut.")
            case .changed: L10n.tr("Das Simulator-Display hat sich während der Aufnahme geändert. Bitte nimm den Screenshot erneut auf.")
            }
        }
    }
}
