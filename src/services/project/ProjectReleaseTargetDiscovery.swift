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
        var result: [Candidate] = []
        for application in XcodeProjectDiscovery.applicationConfigurations(in: directory) {
            let settings = application.settings
            for platform in platforms(settings) {
                let catalyst = platform == .macOS && settings["SUPPORTS_MACCATALYST"] as? String == "YES"
                    && (["iphoneos", "iphonesimulator"].contains(settings["SDKROOT"] as? String ?? "")
                        || !words(settings["SUPPORTED_PLATFORMS"]).contains("macosx"))
                let bundle = catalyst && settings["DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER"] as? String != "NO"
                    ? nil : application.concreteBundleIdentifier
                let destination = platform == .iOS ? "generic/platform=iOS" : (catalyst ? "generic/platform=macOS,variant=Mac Catalyst" : "generic/platform=macOS")
                result.append(Candidate(id: "\(application.projectURL.path)|\(application.targetID)|\(application.configurationID)|\(platform.rawValue)",
                    name: application.name, platform: platform, bundleIdentifier: bundle, scheme: application.name,
                    configuration: application.configuration, destination: destination))
            }
        }
        return result.sorted {
            if ($0.configuration == "Release") != ($1.configuration == "Release") { return $0.configuration == "Release" }
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
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

}
