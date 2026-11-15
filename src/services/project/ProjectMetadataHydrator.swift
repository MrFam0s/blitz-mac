import Foundation

struct ProjectMetadataHydrator {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func hydrate(_ metadata: BlitzProjectMetadata, projectDirectory: URL) -> (metadata: BlitzProjectMetadata, didChange: Bool) {
        var hydrated = metadata
        var didChange = false

        if isBlank(hydrated.bundleIdentifier),
           let bundleIdentifier = autoSelectedBundleIdentifier(projectDirectory: projectDirectory) {
            hydrated.bundleIdentifier = bundleIdentifier
            didChange = true
        }

        return (hydrated, didChange)
    }

    func autoSelectedBundleIdentifier(projectDirectory: URL) -> String? {
        let candidates = discoverBundleIdentifiers(projectDirectory: projectDirectory)
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    func discoverBundleIdentifier(projectDirectory: URL) -> String? {
        autoSelectedBundleIdentifier(projectDirectory: projectDirectory)
    }

    func discoverBundleIdentifiers(projectDirectory: URL) -> [String] {
        let root = projectDirectory.resolvingSymlinksInPath()
        var candidates: [String] = []

        if !XcodeProjectDiscovery.projectURLs(in: root).isEmpty {
            // Once a project describes target membership, only application targets
            // may supply identity. A broad plist scan can otherwise import test,
            // extension or framework IDs, even when the app ID is unresolved.
            for configuration in XcodeProjectDiscovery.applicationConfigurations(in: root) {
                if let bundleID = configuration.concreteBundleIdentifier {
                    candidates.append(bundleID)
                }
            }
        } else {
            candidates.append(contentsOf: discoverBundleIdentifiersInInfoPlists(root: root))
        }

        var seen: Set<String> = []
        var uniqueCandidates: [String] = []
        for candidate in candidates {
            if seen.insert(candidate).inserted {
                uniqueCandidates.append(candidate)
            }
        }

        return uniqueCandidates
    }

    private func discoverBundleIdentifiersInInfoPlists(root: URL) -> [String] {
        var bundleIdentifiers: [String] = []

        for plistURL in findFiles(named: "Info.plist", withExtension: nil, under: root) {
            guard let data = fileManager.contents(atPath: plistURL.path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["CFBundlePackageType"] as? String == "APPL",
                  let rawBundleIdentifier = plist["CFBundleIdentifier"] as? String,
                  let bundleIdentifier = normalizeBundleIdentifier(rawBundleIdentifier) else {
                continue
            }
            bundleIdentifiers.append(bundleIdentifier)
        }

        return bundleIdentifiers
    }

    private func findFiles(named expectedName: String?, withExtension expectedExtension: String?, under root: URL) -> [URL] {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var matches: [URL] = []

        while let entry = enumerator.nextObject() as? URL {
            let name = entry.lastPathComponent

            if Self.skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            if let expectedName, name == expectedName {
                matches.append(entry)
                continue
            }

            if let expectedExtension, entry.pathExtension == expectedExtension {
                matches.append(entry)
                enumerator.skipDescendants()
            }
        }

        return matches.sorted { $0.path < $1.path }
    }

    private func normalizeBundleIdentifier(_ rawValue: String?) -> String? {
        guard var candidate = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return nil
        }

        if candidate.hasPrefix("\""), candidate.hasSuffix("\""), candidate.count >= 2 {
            candidate.removeFirst()
            candidate.removeLast()
        }

        if candidate.contains("$(") || candidate.contains("${") {
            return nil
        }

        guard candidate.contains("."),
              candidate.range(
                of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }

        return candidate
    }

    private func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private static let skippedDirectories: Set<String> = [
        ".build",
        ".git",
        "DerivedData",
        "Pods",
        "build",
        "node_modules"
    ]
}
