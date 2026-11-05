// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// Only documents used by an app target may replace its asset-catalog icon.
/// Looking at the app-icon name alone also matches abandoned .icon documents.
enum ProjectIconComposerSelection {
    static func configuredPackages(in projectFile: URL, candidates: [URL]) -> Set<URL> {
        guard let data = try? Data(contentsOf: projectFile),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]],
              let rootID = plist["rootObject"] as? String,
              let project = objects[rootID], let mainGroup = project["mainGroup"] as? String else { return [] }
        let root = projectFile.deletingLastPathComponent().deletingLastPathComponent()
        var paths: [String: URL] = [:]
        func visit(_ id: String, parent: URL, seen: Set<String>) {
            guard !seen.contains(id), let object = objects[id] else { return }
            let path = object["path"] as? String ?? ""
            guard !path.contains("$("), !path.contains("${") else { return }
            let base: URL
            switch object["sourceTree"] as? String ?? "<group>" {
            case "<group>": base = parent
            case "SOURCE_ROOT": base = root
            case "<absolute>": base = URL(fileURLWithPath: "/")
            default: return
            }
            let url = (path.isEmpty ? base : base.appendingPathComponent(path))
                .resolvingSymlinksInPath().standardizedFileURL
            paths[id] = url
            for child in object["children"] as? [String] ?? [] {
                visit(child, parent: url, seen: seen.union([id]))
            }
        }
        visit(mainGroup, parent: root, seen: [])

        func configurations(_ owner: [String: Any]) -> [[String: Any]] {
            guard let list = owner["buildConfigurationList"] as? String else { return [] }
            return (objects[list]?["buildConfigurations"] as? [String] ?? []).compactMap { objects[$0] }
        }
        let projectConfigurations = configurations(project)
        var selected: Set<URL> = []
        for targetID in project["targets"] as? [String] ?? [] {
            guard let target = objects[targetID], target["isa"] as? String == "PBXNativeTarget",
                  target["productType"] as? String == "com.apple.product-type.application" else { continue }
            var names: Set<String> = []
            for configuration in configurations(target) {
                let own = configuration["buildSettings"] as? [String: Any] ?? [:]
                let inherited = projectConfigurations.first { ($0["name"] as? String) == (configuration["name"] as? String) }?["buildSettings"] as? [String: Any] ?? [:]
                if let name = own["ASSETCATALOG_COMPILER_APPICON_NAME"] as? String
                    ?? inherited["ASSETCATALOG_COMPILER_APPICON_NAME"] as? String,
                   !name.isEmpty, !name.contains("$("), !name.contains("${") { names.insert(name) }
            }
            guard !names.isEmpty else { continue }
            let matching = candidates.filter { names.contains($0.deletingPathExtension().lastPathComponent) }
            let resourcePhases = (target["buildPhases"] as? [String] ?? []).filter {
                objects[$0]?["isa"] as? String == "PBXResourcesBuildPhase"
            }
            for phase in resourcePhases {
                for buildFile in objects[phase]?["files"] as? [String] ?? [] {
                    guard let reference = objects[buildFile]?["fileRef"] as? String,
                          let url = paths[reference], url.pathExtension == "icon",
                          names.contains(url.deletingPathExtension().lastPathComponent) else { continue }
                    selected.insert(url)
                }
            }
            for groupID in target["fileSystemSynchronizedGroups"] as? [String] ?? [] {
                guard let group = objects[groupID], group["isa"] as? String == "PBXFileSystemSynchronizedRootGroup",
                      let directory = paths[groupID] else { continue }
                let exceptions = (group["exceptions"] as? [String] ?? []).compactMap { objects[$0] }.filter {
                    ($0["target"] as? String) == targetID
                }.flatMap { $0["membershipExceptions"] as? [String] ?? [] }
                for candidate in matching where candidate.path.hasPrefix(directory.path + "/") {
                    let relative = String(candidate.path.dropFirst(directory.path.count + 1))
                    guard !exceptions.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) else { continue }
                    selected.insert(candidate)
                }
            }
        }
        return selected
    }
}
