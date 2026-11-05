// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import CryptoKit
import Foundation
import ImageIO

/// A configured Icon Composer document, not a flattened layer image.
struct ProjectIconComposerSource {
    let packageURL: URL
    let platform: String
    let cacheKey: String

    init?(packageURL: URL, projectRoot: URL) {
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        let package = packageURL.resolvingSymlinksInPath().standardizedFileURL
        guard package.pathExtension == "icon", package.path.hasPrefix(root.path + "/"),
              (try? package.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        let document = package.appendingPathComponent("icon.json").resolvingSymlinksInPath()
        guard document.deletingLastPathComponent() == package,
              let data = try? Data(contentsOf: document),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]],
              groups.allSatisfy({ $0["layers"] is [[String: Any]] }),
              let platforms = json["supported-platforms"] as? [String: Any] else { return nil }
        let squares: [String]
        if let list = platforms["squares"] as? [String], !list.isEmpty,
           list.allSatisfy({ ["macOS", "iOS"].contains($0) }) { squares = list }
        else if platforms["squares"] as? String == "shared" { squares = ["macOS", "iOS"] }
        else { return nil }
        // Shared/iOS documents use the square iOS export. macOS-only documents
        // use Apple's macOS composition (including native margins/materials).
        self.platform = squares == ["macOS"] ? "macOS" : "iOS"
        var names: Set<String> = []
        func collectImages(_ value: Any) {
            if let object = value as? [String: Any] {
                if let name = object["image-name"] as? String { names.insert(name) }
                for nested in object.values { collectImages(nested) }
            } else if let array = value as? [Any] {
                for nested in array { collectImages(nested) }
            }
        }
        collectImages(json)
        guard !names.isEmpty || json["fill"] != nil || json["fill-specializations"] != nil else { return nil }
        let assets = package.appendingPathComponent("Assets").resolvingSymlinksInPath()
        guard assets.path.hasPrefix(package.path + "/") else { return nil }
        var fingerprint = SHA256()
        fingerprint.update(data: Data((package.path + "\0" + platform + "\0").utf8))
        fingerprint.update(data: data)
        for name in names.sorted() {
            guard !name.isEmpty, !name.hasPrefix("/") else { return nil }
            let asset = assets.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
            guard asset.path.hasPrefix(assets.path + "/"),
                  (try? asset.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let contents = try? Data(contentsOf: asset), Self.isValidLayer(contents, url: asset) else { return nil }
            fingerprint.update(data: Data(("\0" + name + "\0").utf8))
            fingerprint.update(data: contents)
        }
        self.packageURL = package
        self.cacheKey = fingerprint.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidLayer(_ data: Data, url: URL) -> Bool {
        if url.pathExtension.lowercased() == "svg" {
            let validator = SVGRootValidator()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = validator
            return parser.parse() && validator.isSVG
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return image.width > 0 && image.height > 0
    }
}

private final class SVGRootValidator: NSObject, XMLParserDelegate {
    private var hasRoot = false
    var isSVG = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if !hasRoot { hasRoot = true; isSVG = elementName == "svg" }
    }
}
