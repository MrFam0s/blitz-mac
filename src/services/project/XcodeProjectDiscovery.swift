// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// A read-only view of application targets shared by import and release discovery.
/// It does not execute a project, resolve arbitrary build variables, or infer an
/// app identity from test targets and generated/dependency bundles.
enum XcodeProjectDiscovery {
    struct ApplicationConfiguration {
        let projectURL: URL
        let targetID: String
        let name: String
        let configurationID: String
        let configuration: String
        let settings: [String: Any]
        let hasUnresolvedBaseConfiguration: Bool

        var concreteBundleIdentifier: String? {
            guard !hasUnresolvedBaseConfiguration,
                  !settings.keys.contains(where: { $0.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER[") }) else { return nil }
            if let rawValue = settings["PRODUCT_BUNDLE_IDENTIFIER"] {
                guard let value = rawValue as? String, AppCreationIdentity.validBundleID(value) else { return nil }
                return value
            }
            return XcodeProjectDiscovery.appInfoPlistBundleIdentifier(settings: settings,
                projectDirectory: projectURL.deletingLastPathComponent())
        }
    }

    static func projectURLs(in directory: URL) -> [URL] {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        if root.pathExtension == "xcodeproj" { return [root] }
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var projects: [URL] = []
        while let entry = enumerator.nextObject() as? URL {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Resolve only the explicitly selected root. A nested link can lead to
            // another project or form a cycle and is never part of this import.
            if values?.isSymbolicLink == true || skippedDirectories.contains(entry.lastPathComponent)
                || ["app", "framework", "xcframework", "xctest", "xcarchive"].contains(entry.pathExtension) {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true, entry.pathExtension == "xcodeproj" {
                projects.append(entry.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        return projects.sorted { $0.path < $1.path }
    }

    static func applicationConfigurations(in directory: URL) -> [ApplicationConfiguration] {
        projectURLs(in: directory).flatMap { configurations(in: $0) }
    }

    static func configurations(in projectURL: URL) -> [ApplicationConfiguration] {
        let modern = projectURL.appendingPathComponent("project.xcproj")
        let legacy = projectURL.appendingPathComponent("project.pbxproj")
        let fm = FileManager.default
        let hasModern = fm.fileExists(atPath: modern.path)
        let hasLegacy = fm.fileExists(atPath: legacy.path)
        // Two definitions are ambiguous; do not silently pick a stale identity.
        guard hasModern != hasLegacy else { return [] }
        if hasModern {
            guard let document = decodeModernProject(at: modern) else { return [] }
            return modernConfigurations(document, projectURL: projectURL)
        }
        guard let data = try? Data(contentsOf: legacy),
              let document = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        return legacyConfigurations(document, projectURL: projectURL)
    }

    /// Foundation parses Xcode's comments and trailing commas without rewriting
    /// strings (which can themselves contain comment markers or commas).
    static func decodeModernProject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeModernProject(data: data)
    }

    static func decodeModernProject(data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var ranges = JSON5SourceRanges(text)
        // JSONDecoder accepts duplicate object keys. An identity must not depend
        // on which duplicate value a decoder happens to keep.
        guard (try? ranges.parseDocument()) != nil else { return nil }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        guard let values = try? decoder.decode([String: JSONValue].self, from: data) else { return nil }
        return values.mapValues(\.foundationValue)
    }

    /// Resolve exact configuration selectors only. SDK/architecture/glob selectors
    /// stay conditional, so the identity reader cannot claim a concrete value.
    static func resolveConfigurationSettings(_ settings: [String: Any], configuration: String) -> [String: Any] {
        var result = settings.filter { !$0.key.contains("[config=") }
        for key in settings.keys.sorted() where key.contains("[config=") {
            guard let start = key.range(of: "[config="),
                  let end = key[start.upperBound...].firstIndex(of: "]") else {
                result[key] = settings[key]
                continue
            }
            let condition = String(key[start.upperBound..<end])
            // A glob cannot safely be treated as a literal nonmatching name.
            guard !condition.contains("*"), !condition.contains("?"), !condition.contains("[") else {
                result[key] = settings[key]
                continue
            }
            guard condition == configuration else { continue }
            let resolvedKey = String(key[..<start.lowerBound]) + String(key[key.index(after: end)...])
            result[resolvedKey] = settings[key]
        }
        return result
    }

    /// Xcode's JSON5 format applies an unconditional value to every configuration,
    /// even when a sibling exact [config=...] assignment exists. This differs
    /// from the legacy build-settings dictionary; source ordering has no effect.
    /// Verified against Xcode's resolved settings with nondefault sentinel values.
    static func resolveModernConfigurationSettings(_ settings: [String: Any], configuration: String) -> [String: Any] {
        var result = resolveConfigurationSettings(settings, configuration: configuration)
        for (key, value) in settings where !key.contains("[config=") {
            result[key] = value
        }
        return result
    }

    private static func legacyConfigurations(_ document: [String: Any], projectURL: URL) -> [ApplicationConfiguration] {
        guard let objects = document["objects"] as? [String: [String: Any]] else { return [] }
        let project = (document["rootObject"] as? String).flatMap { objects[$0] }
        let projectList = (project?["buildConfigurationList"] as? String).flatMap { objects[$0] }
        let projectConfigs = (projectList?["buildConfigurations"] as? [String] ?? []).compactMap { objects[$0] }
        var result: [ApplicationConfiguration] = []
        let targetIDs = project?["targets"] as? [String] ?? Array(objects.keys)
        for targetID in Set(targetIDs).sorted() {
            guard let target = objects[targetID], target["isa"] as? String == "PBXNativeTarget",
                  target["productType"] as? String == "com.apple.product-type.application",
                  let name = target["name"] as? String,
                  let listID = target["buildConfigurationList"] as? String,
                  let configIDs = objects[listID]?["buildConfigurations"] as? [String] else { continue }
            for configID in configIDs {
                guard let config = objects[configID], let configName = config["name"] as? String else { continue }
                let projectConfig = projectConfigs.first { $0["name"] as? String == configName }
                let projectSettings = resolveConfigurationSettings(projectConfig?["buildSettings"] as? [String: Any] ?? [:], configuration: configName)
                let targetSettings = resolveConfigurationSettings(config["buildSettings"] as? [String: Any] ?? [:], configuration: configName)
                let unresolved = unresolvedBaseConfiguration(projectHasBase: projectConfig?["baseConfigurationReference"] != nil,
                    targetHasBase: config["baseConfigurationReference"] != nil,
                    projectSettings: projectSettings, targetSettings: targetSettings)
                result.append(ApplicationConfiguration(projectURL: projectURL, targetID: targetID, name: name,
                    configurationID: configID, configuration: configName,
                    settings: projectSettings.merging(targetSettings) { _, target in target },
                    hasUnresolvedBaseConfiguration: unresolved))
            }
        }
        return result
    }

    private static func modernConfigurations(_ document: [String: Any], projectURL: URL) -> [ApplicationConfiguration] {
        guard let targets = document["targets"] as? [[String: Any]] else { return [] }
        var configurations = document["configurations"] as? [String] ?? []
        if configurations.isEmpty, let defaultName = document["default-configuration"] as? String {
            configurations = [defaultName]
        }
        guard !configurations.isEmpty, Set(configurations).count == configurations.count else { return [] }
        var result: [ApplicationConfiguration] = []
        for target in targets {
            guard target["product-type"] as? String == "application",
                  let name = target["name"] as? String, !name.isEmpty else { continue }
            let targetID = target["id"] as? String ?? name
            // Names can stand in for IDs only if they uniquely identify a target.
            guard !targetID.isEmpty,
                  targets.filter({ ($0["id"] as? String ?? $0["name"] as? String) == targetID }).count == 1 else { continue }
            for configuration in configurations where !configuration.isEmpty {
                let projectSettings = resolveModernConfigurationSettings(document["build-settings"] as? [String: Any] ?? [:], configuration: configuration)
                let targetSettings = resolveModernConfigurationSettings(target["build-settings"] as? [String: Any] ?? [:], configuration: configuration)
                let unresolved = unresolvedBaseConfiguration(projectHasBase: hasExternalConfiguration(document),
                    targetHasBase: hasExternalConfiguration(target), projectSettings: projectSettings, targetSettings: targetSettings)
                result.append(ApplicationConfiguration(projectURL: projectURL, targetID: targetID, name: name,
                    configurationID: configuration, configuration: configuration,
                    settings: projectSettings.merging(targetSettings) { _, target in target },
                    hasUnresolvedBaseConfiguration: unresolved))
            }
        }
        return result
    }

    private static func unresolvedBaseConfiguration(projectHasBase: Bool, targetHasBase: Bool,
        projectSettings: [String: Any], targetSettings: [String: Any]) -> Bool {
        // Explicit target settings override xcconfig input. A target xcconfig can
        // override the project value, so that inherited value alone is not proof.
        if targetSettings["PRODUCT_BUNDLE_IDENTIFIER"] != nil { return false }
        if targetHasBase { return true }
        return projectHasBase && projectSettings["PRODUCT_BUNDLE_IDENTIFIER"] == nil
    }

    private static func appInfoPlistBundleIdentifier(settings: [String: Any], projectDirectory: URL) -> String? {
        // Only a plist explicitly linked to this application target can supply a
        // missing identity. It cannot override an unresolved or invalid setting.
        guard !settings.keys.contains(where: { $0.hasPrefix("INFOPLIST_FILE[") }),
              let rawPath = settings["INFOPLIST_FILE"] as? String else { return nil }
        var path = rawPath
        for variable in ["$(SRCROOT)", "${SRCROOT}", "$(PROJECT_DIR)", "${PROJECT_DIR}"] {
            path = path.replacingOccurrences(of: variable, with: projectDirectory.path)
        }
        guard !path.isEmpty, !path.contains("$("), !path.contains("${") else { return nil }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : projectDirectory.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        let root = projectDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = plist["CFBundleIdentifier"] as? String,
              AppCreationIdentity.validBundleID(value) else { return nil }
        return value
    }

    private static func hasExternalConfiguration(_ object: [String: Any]) -> Bool {
        object.keys.contains { key in
            key == "base-configuration" || key.hasPrefix("base-configuration[")
                || key == "configuration-file" || key.hasPrefix("configuration-file[")
                || key == "base-configuration-reference" || key == "xcconfig"
        }
    }

    private static let skippedDirectories: Set<String> = [
        ".build", ".git", "DerivedData", "Pods", "build", "node_modules", "Carthage", "SourcePackages", "vendor", "Vendor"
    ]

    private enum JSONValue: Decodable {
        case string(String), bool(Bool), number(Double), array([JSONValue]), object([String: JSONValue]), null

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
            else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
            else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
            else if let decoded = try? value.decode([JSONValue].self) { self = .array(decoded) }
            else { self = .object(try value.decode([String: JSONValue].self)) }
        }

        var foundationValue: Any {
            switch self {
            case .string(let value): return value
            case .bool(let value): return value
            case .number(let value): return value
            case .array(let values): return values.map(\.foundationValue)
            case .object(let values): return values.mapValues(\.foundationValue)
            case .null: return NSNull()
            }
        }
    }
}
