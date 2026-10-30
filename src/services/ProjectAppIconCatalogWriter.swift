import AppKit
import ImageIO

enum ProjectAppIconCatalogWriter {
    private static let skippedDirectories: Set<String> = [
        "node_modules", "Pods", ".git", ".build", "DerivedData",
        "build", "target", "vendor", "deps", "ThirdParty"
    ]

    /// Update the first project catalog, preserving separately authored appearance variants.
    static func write(source: CGImage, projectPath: String) throws {
        let root = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }
        var catalogs: [URL] = []
        while let entry = enumerator.nextObject() as? URL {
            if skippedDirectories.contains(entry.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if entry.lastPathComponent == "Contents.json",
               entry.deletingLastPathComponent().lastPathComponent == "AppIcon.appiconset" {
                catalogs.append(entry)
            }
        }
        for catalog in catalogs.sorted(by: { $0.path < $1.path }) {
            let directory = catalog.deletingLastPathComponent().resolvingSymlinksInPath()
            guard directory.path.hasPrefix(root.path + "/") else {
                throw CatalogError.outsideProject
            }
            let data = try Data(contentsOf: catalog)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = json["images"] as? [[String: Any]] else {
                throw CatalogError.invalidCatalog
            }
            var protectedFiles: Set<URL> = []
            for entry in images where hasAppearance(entry) {
                if let filename = entry["filename"] as? String {
                    protectedFiles.insert(try destination(filename, directory: directory))
                }
            }
            var writes: [URL: Data] = [:]
            for entry in images where !hasAppearance(entry) {
                guard let filename = entry["filename"] as? String else { continue }
                let url = try destination(filename, directory: directory)
                guard !protectedFiles.contains(url) else { throw CatalogError.sharedAppearanceFilename }
                let dimensions = try dimensions(for: entry, existingFile: url, source: source)
                writes[url] = try png(source: source, width: dimensions.width, height: dimensions.height)
            }
            // Validate and render every entry before changing any catalog file.
            for (url, png) in writes.sorted(by: { $0.key.path < $1.key.path }) {
                try png.write(to: url, options: .atomic)
            }
            if !writes.isEmpty { return }
        }
    }

    private static func hasAppearance(_ entry: [String: Any]) -> Bool {
        !(entry["appearances"] as? [[String: Any]] ?? []).isEmpty
    }

    private static func destination(_ filename: String, directory: URL) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\") else {
            throw CatalogError.unsafeFilename
        }
        let url = directory.appendingPathComponent(filename).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == directory else { throw CatalogError.unsafeFilename }
        return url
    }

    private static func dimensions(
        for entry: [String: Any], existingFile: URL, source: CGImage
    ) throws -> (width: Int, height: Int) {
        guard let size = entry["size"] as? String else {
            // Older universal entries may omit size; preserve an existing bitmap's dimensions.
            if let imageSource = CGImageSourceCreateWithURL(existingFile as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                return (image.width, image.height)
            }
            return (source.width, source.height)
        }
        let sides = size.split(separator: "x")
        let scaleText = entry["scale"] as? String ?? "1x"
        guard sides.count == 2, let pointWidth = Double(sides[0]), let pointHeight = Double(sides[1]),
              scaleText.hasSuffix("x"),
              let scale = Double(scaleText.dropLast()), scale > 0 else {
            throw CatalogError.invalidDimensions
        }
        let width = pointWidth * scale
        let height = pointHeight * scale
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 4096, height <= 4096,
              width.rounded() == width, height.rounded() == height else {
            throw CatalogError.invalidDimensions
        }
        return (Int(width), Int(height))
    }

    private static func png(source: CGImage, width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CatalogError.cannotRender }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CatalogError.cannotRender
        }
        return png
    }

    private enum CatalogError: LocalizedError {
        case invalidCatalog, outsideProject, unsafeFilename, sharedAppearanceFilename, invalidDimensions, cannotRender

        var errorDescription: String? {
            switch self {
            case .invalidCatalog: return "The app icon catalog has invalid contents."
            case .outsideProject: return "The app icon catalog points outside this project."
            case .unsafeFilename: return "The app icon catalog contains an unsafe image filename."
            case .sharedAppearanceFilename: return "Default and appearance-specific app icons must use separate image files."
            case .invalidDimensions: return "The app icon catalog contains an invalid image size."
            case .cannotRender: return "Could not render an app icon image."
            }
        }
    }
}
