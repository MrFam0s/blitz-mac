import Foundation

/// Reads application targets and their concrete configurations without invoking
/// Xcode or guessing a platform from unrelated test/dependency settings.
enum ProjectReleaseTargetDiscovery {
    struct Candidate: Identifiable, Equatable {
        let id: String
        let name: String
        let platform: ProjectPlatform
        let bundleIdentifier: String?
        let scheme: String
        let configuration: String
        let destination: String
        var label: String { "\(name) · \(platform.rawValue) · \(configuration)" }
    }

    static func discover(in directory: URL) -> [Candidate] {
        let root = directory.resolvingSymlinksInPath()
        let fm = FileManager.default
        let locations = [root] + ["ios", "macos", "apple"].map { root.appendingPathComponent($0) }
        var result: [Candidate] = []
        for location in locations {
            let projects = ((try? fm.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "xcodeproj" }
            for project in projects {
                guard let data = try? Data(contentsOf: project.appendingPathComponent("project.pbxproj")),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let objects = plist["objects"] as? [String: [String: Any]] else { continue }
                let projectObject = (plist["rootObject"] as? String).flatMap { objects[$0] }
                let projectList = (projectObject?["buildConfigurationList"] as? String).flatMap { objects[$0] }
                let projectConfigs = (projectList?["buildConfigurations"] as? [String] ?? []).compactMap { objects[$0] }
                for (id, target) in objects where target["isa"] as? String == "PBXNativeTarget"
                    && target["productType"] as? String == "com.apple.product-type.application" {
                    guard let name = target["name"] as? String,
                          let listID = target["buildConfigurationList"] as? String,
                          let configIDs = objects[listID]?["buildConfigurations"] as? [String] else { continue }
                    for configID in configIDs {
                        guard let config = objects[configID], let configName = config["name"] as? String else { continue }
                        var settings = projectConfigs.first { $0["name"] as? String == configName }?["buildSettings"] as? [String: Any] ?? [:]
                        settings.merge(config["buildSettings"] as? [String: Any] ?? [:]) { _, target in target }
                        for platform in platforms(settings) {
                            let catalyst = platform == .macOS && settings["SUPPORTS_MACCATALYST"] as? String == "YES"
                                && (["iphoneos", "iphonesimulator"].contains(settings["SDKROOT"] as? String ?? "")
                                    || !words(settings["SUPPORTED_PLATFORMS"]).contains("macosx"))
                            let bundle = concreteBundleID(settings, catalyst: catalyst)
                            let destination = platform == .iOS ? "generic/platform=iOS" : (catalyst ? "generic/platform=macOS,variant=Mac Catalyst" : "generic/platform=macOS")
                            result.append(Candidate(id: "\(project.path)|\(id)|\(configID)|\(platform.rawValue)",
                                name: name, platform: platform, bundleIdentifier: bundle, scheme: name, configuration: configName, destination: destination))
                        }
                    }
                }
            }
        }
        return result.sorted {
            if ($0.configuration == "Release") != ($1.configuration == "Release") { return $0.configuration == "Release" }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    private static func words(_ value: Any?) -> Set<String> {
        if let values = value as? [String] { return Set(values) }
        return Set((value as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private static func platforms(_ settings: [String: Any]) -> [ProjectPlatform] {
        let supported = words(settings["SUPPORTED_PLATFORMS"])
        var result: [ProjectPlatform] = []
        if !supported.isEmpty {
            if !supported.isDisjoint(with: ["iphoneos", "iphonesimulator"]) { result.append(.iOS) }
            if supported.contains("macosx") { result.append(.macOS) }
            // A Catalyst build is a native MAC_OS release, never iOS-on-Mac.
            if result.contains(.iOS), settings["SUPPORTS_MACCATALYST"] as? String == "YES", !result.contains(.macOS) { result.append(.macOS) }
            return result
        }
        switch settings["SDKROOT"] as? String {
        case "iphoneos", "iphonesimulator":
            result = [.iOS]
            if settings["SUPPORTS_MACCATALYST"] as? String == "YES" { result.append(.macOS) }
            return result
        case "macosx": return [.macOS]
        default:
            let ios = settings["IPHONEOS_DEPLOYMENT_TARGET"] != nil
            let mac = settings["MACOSX_DEPLOYMENT_TARGET"] != nil
            // Ambiguous inherited deployment settings need user selection.
            if ios != mac { return ios ? [.iOS] : [.macOS] }
            return []
        }
    }

    private static func concreteBundleID(_ settings: [String: Any], catalyst: Bool) -> String? {
        let conditional = settings.keys.contains { $0.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER[") }
        guard !conditional else { return nil }
        if catalyst, settings["DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER"] as? String != "NO" { return nil }
        guard let value = settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String,
              AppCreationIdentity.validBundleID(value) else { return nil }
        return value
    }
}
