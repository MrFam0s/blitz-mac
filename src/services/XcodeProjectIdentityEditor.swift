// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// Selects an application target before touching its settings. Other targets and
/// project-wide settings are deliberately preserved, including their formatting.
struct XcodeProjectIdentityEditor {
    struct Selection {
        let projectURL: URL
        let fileURL: URL
        let targetID: String
        let targetName: String
        let configurationIDs: [String]
    }

    struct IdentityError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Document {
        let url: URL
        let text: String
        let plist: [String: Any]
        let objects: [String: [String: Any]]
        let modernTargets: [[String: Any]]?
    }

    private func document(_ project: URL) throws -> Document {
        let legacy = project.appendingPathComponent("project.pbxproj")
        let modern = project.appendingPathComponent("project.xcproj")
        let fm = FileManager.default
        guard !(fm.fileExists(atPath: legacy.path) && fm.fileExists(atPath: modern.path)) else {
            throw IdentityError(message: "Both Xcode project formats are present. Resolve the active project file in Xcode before changing its settings.")
        }
        let url = fm.fileExists(atPath: modern.path) ? modern : legacy
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw IdentityError(message: "Cannot read Xcode project: \(project.lastPathComponent)")
        }
        if url == modern {
            guard let plist = XcodeProjectDiscovery.decodeModernProject(data: data),
                  let targets = plist["targets"] as? [[String: Any]] else {
                throw IdentityError(message: "Cannot read Xcode project: \(project.lastPathComponent)")
            }
            // Source ranges reject duplicate keys before selection as well as editing.
            var ranges = JSON5SourceRanges(text)
            _ = try ranges.parseDocument()
            return Document(url: url, text: text, plist: plist, objects: [:], modernTargets: targets)
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]] else {
            throw IdentityError(message: "Cannot read Xcode project: \(project.lastPathComponent)")
        }
        return Document(url: url, text: text, plist: plist, objects: objects, modernTargets: nil)
    }

    func select(projectPath: String, scheme: String? = nil, configuration: String? = nil) throws -> Selection {
        let root = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath()
        let fm = FileManager.default
        let directories = [root] + ["ios", "macos", "apple"].map { root.appendingPathComponent($0) }
        let projects = XcodeProjectDiscovery.projectURLs(in: root)
        var schemeContainers: [URL] = []
        for directory in directories {
            let children = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            schemeContainers += children.filter { ["xcodeproj", "xcworkspace"].contains($0.pathExtension) }
        }
        schemeContainers += projects.filter { !schemeContainers.contains($0) }
        var candidates: [(Document, String, String)] = []
        for project in projects.sorted(by: { $0.path < $1.path }) {
            let doc = try document(project)
            if let targets = doc.modernTargets {
                for target in targets where target["product-type"] as? String == "application" {
                    guard let name = target["name"] as? String else { continue }
                    let id = target["id"] as? String ?? name
                    guard !id.isEmpty, !name.isEmpty,
                          targets.filter({ ($0["id"] as? String ?? $0["name"] as? String) == id }).count == 1 else {
                        throw IdentityError(message: "The Xcode project has ambiguous target identities. Resolve them in Xcode before changing settings.")
                    }
                    candidates.append((doc, id, name))
                }
                continue
            }
            let rootObject = (doc.plist["rootObject"] as? String).flatMap { doc.objects[$0] }
            let listedTargets = (rootObject?["targets"] as? [String]).map(Set.init)
            for (id, object) in doc.objects where object["isa"] as? String == "PBXNativeTarget"
                && object["productType"] as? String == "com.apple.product-type.application"
                && (listedTargets?.contains(id) ?? true) {
                guard let name = object["name"] as? String else { continue }
                candidates.append((doc, id, name))
            }
        }
        if let scheme = scheme?.trimmingCharacters(in: .whitespacesAndNewlines), !scheme.isEmpty {
            let references = try schemeReferences(scheme, containers: schemeContainers)
            if references.isEmpty {
                // Xcode's autogenerated scheme normally has the application target's name.
                candidates = candidates.filter { $0.2 == scheme }
            } else {
                candidates = candidates.filter { candidate in
                    references.contains { $0.id == candidate.1 && $0.project == candidate.0.url.deletingLastPathComponent().resolvingSymlinksInPath() }
                }
            }
        }
        guard candidates.count == 1, let (doc, id, name) = candidates.first else {
            throw IdentityError(message: candidates.isEmpty
                ? "No application target could be selected. Choose the app's Xcode scheme in build settings."
                : "Multiple application targets were found. Choose an unambiguous app scheme before changing signing or bundle IDs.")
        }
        if doc.modernTargets != nil {
            guard let allNames = doc.plist["configurations"] as? [String], !allNames.isEmpty,
                  Set(allNames).count == allNames.count,
                  allNames.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "[]*?")) == nil }) else {
                throw IdentityError(message: "The selected application target has no unambiguous build configurations.")
            }
            let names = allNames.filter { configuration == nil || $0 == configuration }
            guard !names.isEmpty else { throw IdentityError(message: "The selected app has no '\(configuration ?? "")' configuration.") }
            return Selection(projectURL: doc.url.deletingLastPathComponent(), fileURL: doc.url,
                targetID: id, targetName: name, configurationIDs: names)
        }
        guard let target = doc.objects[id], let listID = target["buildConfigurationList"] as? String,
              let allIDs = doc.objects[listID]?["buildConfigurations"] as? [String] else {
            throw IdentityError(message: "The selected application target has no build configurations.")
        }
        let ids = allIDs.filter { configuration == nil || doc.objects[$0]?["name"] as? String == configuration }
        guard !ids.isEmpty else { throw IdentityError(message: "The selected app has no '\(configuration ?? "")' configuration.") }
        for (otherID, other) in doc.objects where otherID != id && ["PBXNativeTarget", "PBXAggregateTarget", "PBXProject"].contains(other["isa"] as? String ?? "") {
            if let otherList = other["buildConfigurationList"] as? String,
               let otherConfigs = doc.objects[otherList]?["buildConfigurations"] as? [String],
               !Set(ids).isDisjoint(with: otherConfigs) {
                throw IdentityError(message: "The selected app shares build configurations with another target or the project. Change its bundle ID in Xcode.")
            }
        }
        return Selection(projectURL: doc.url.deletingLastPathComponent(), fileURL: doc.url, targetID: id, targetName: name, configurationIDs: ids)
    }

    private func schemeReferences(_ scheme: String, containers: [URL]) throws -> [(id: String, project: URL)] {
        var references: [(String, URL)] = []
        for container in containers {
            var roots = [container.appendingPathComponent("xcshareddata/xcschemes")]
            let users = (try? FileManager.default.contentsOfDirectory(at: container.appendingPathComponent("xcuserdata"), includingPropertiesForKeys: nil)) ?? []
            roots += users.map { $0.appendingPathComponent("xcschemes") }
            for root in roots {
                let url = root.appendingPathComponent(scheme).appendingPathExtension("xcscheme")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let xml = try XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever])
                let archiveEntries = try xml.nodes(forXPath: "//BuildActionEntry[@buildForArchiving='YES']/BuildableReference")
                // Explicit archive entries are preferred over test-only dependencies.
                let nodes = archiveEntries.isEmpty ? try xml.nodes(forXPath: "//LaunchAction//BuildableReference") : archiveEntries
                for case let node as XMLElement in nodes {
                    if let id = node.attribute(forName: "BlueprintIdentifier")?.stringValue,
                       let location = node.attribute(forName: "ReferencedContainer")?.stringValue {
                        guard location.hasPrefix("container:") else {
                            throw IdentityError(message: "Unsupported scheme project reference. Choose a scheme with an explicit project container.")
                        }
                        let path = String(location.dropFirst("container:".count))
                        let project = URL(fileURLWithPath: path, relativeTo: container.deletingLastPathComponent())
                            .standardizedFileURL.resolvingSymlinksInPath()
                        references.append((id, project))
                    }
                }
            }
        }
        return references
    }

    @discardableResult
    func update(projectPath: String, bundleID: String, scheme: String? = nil, configuration: String? = nil, teamID: String? = nil, dryRun: Bool = false, expectedOriginal: Data? = nil) throws -> Data {
        guard bundleID.range(of: #"\A[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+\z"#, options: .regularExpression) != nil else {
            throw IdentityError(message: "Invalid bundle ID. Use ASCII letters, numbers, hyphens and dot-separated components.")
        }
        let selection = try select(projectPath: projectPath, scheme: scheme, configuration: configuration)
        let doc = try document(selection.projectURL)
        if let expectedOriginal, expectedOriginal != Data(doc.text.utf8) {
            throw IdentityError(message: "The Xcode project changed before this update. Retry after saving Xcode changes.")
        }
        if doc.modernTargets != nil {
            return try updateModern(doc, selection: selection, bundleID: bundleID, configuration: configuration,
                teamID: teamID, dryRun: dryRun)
        }
        var parser = OpenStepRanges(doc.text)
        let root = try parser.parse()
        guard let objectNodes = root.entries["objects"] else { throw IdentityError(message: "Cannot locate Xcode objects safely.") }
        var edits: [(Range<String.Index>, String)] = []
        var replacements = ["PRODUCT_BUNDLE_IDENTIFIER": bundleID]
        if let teamID, !teamID.isEmpty {
            replacements["DEVELOPMENT_TEAM"] = teamID
            replacements["CODE_SIGN_STYLE"] = "Automatic"
        }
        for id in selection.configurationIDs {
            guard let object = doc.objects[id], let settings = object["buildSettings"] as? [String: Any],
                  let node = objectNodes.entries[id]?.entries["buildSettings"] else {
                throw IdentityError(message: "Cannot locate the selected target's build settings safely.")
            }
            // Conditional settings can override an ordinary assignment; never guess
            // which SDK-specific identity the user intended to change.
            let conditionalKeys = settings.keys.filter { key in replacements.keys.contains { key.hasPrefix($0 + "[") } }
            guard conditionalKeys.isEmpty else {
                throw IdentityError(message: "The selected app uses conditional signing or bundle-ID settings. Resolve them in Xcode before changing this value.")
            }
            for key in replacements.keys.sorted() {
                let value = replacements[key]!
                if let valueNode = node.entries[key] {
                    edits.append((valueNode.range, Self.quoted(value)))
                } else {
                    let end = doc.text.index(before: node.range.upperBound)
                    edits.append((end..<end, "\n\t\t\t\t\(key) = \(Self.quoted(value));\n\t\t\t"))
                }
            }
        }
        var result = doc.text
        for (range, replacement) in edits.sorted(by: {
            $0.0.lowerBound == $1.0.lowerBound ? $0.0.upperBound > $1.0.upperBound : $0.0.lowerBound > $1.0.lowerBound
        }) {
            result.replaceSubrange(range, with: replacement)
        }
        // Reparse before the atomic write, so unsupported syntax never leaves a
        // partly rewritten user project behind.
        _ = try PropertyListSerialization.propertyList(from: Data(result.utf8), format: nil)
        guard try Data(contentsOf: doc.url) == Data(doc.text.utf8) else {
            throw IdentityError(message: "The Xcode project changed during this update. Retry after saving Xcode changes.")
        }
        let updatedData = Data(result.utf8)
        if !dryRun { try updatedData.write(to: doc.url, options: .atomic) }
        return updatedData
    }

    private func updateModern(_ doc: Document, selection: Selection, bundleID: String,
                              configuration: String?, teamID: String?, dryRun: Bool) throws -> Data {
        guard let targets = doc.modernTargets,
              let targetIndex = targets.firstIndex(where: { ($0["id"] as? String ?? $0["name"] as? String) == selection.targetID }),
              let settings = targets[targetIndex]["build-settings"] as? [String: Any] else {
            throw IdentityError(message: "Cannot locate the selected application's build settings safely.")
        }
        var parser = JSON5SourceRanges(doc.text)
        let root = try parser.parseDocument()
        guard let targetNodes = root.entries["targets"]?.elements, targetNodes.indices.contains(targetIndex),
              let settingsNode = targetNodes[targetIndex].entries["build-settings"] else {
            throw IdentityError(message: "Cannot locate the selected application's build settings safely.")
        }
        var replacements = ["PRODUCT_BUNDLE_IDENTIFIER": bundleID]
        if let teamID, !teamID.isEmpty {
            replacements["DEVELOPMENT_TEAM"] = teamID
            replacements["CODE_SIGN_STYLE"] = "Automatic"
        }
        let allConfigurations = doc.plist["configurations"] as? [String] ?? []
        let projectSettings = doc.plist["build-settings"] as? [String: Any] ?? [:]
        // In xcproj an unconditional setting wins over its configuration-specific
        // entries, regardless of their source order. To change just one config,
        // expand an existing base into exact entries for every configuration.
        // Preserve the base's effective value for all unselected configurations,
        // including when an old conditional entry was previously ineffective.
        // SDK/architecture/wildcard overrides remain an explicit refusal.
        for key in replacements.keys {
            let allowed = Set(allConfigurations.map { "\(key)[config=\($0)]" })
            let unsupported = Set(settings.keys).union(projectSettings.keys).contains {
                $0.hasPrefix(key + "[") && !allowed.contains($0)
            }
            guard !unsupported else {
                throw IdentityError(message: "The selected app uses conditional signing or bundle-ID settings. Resolve them in Xcode before changing this value.")
            }
        }
        var values: [String: String] = [:]
        var removeBaseKeys: Set<String> = []
        for (key, value) in replacements {
            if let configuration {
                if let originalBase = settings[key] {
                    guard let originalValue = originalBase as? String else {
                        throw IdentityError(message: "The selected app has an unsupported signing or bundle-ID value. No settings were changed.")
                    }
                    removeBaseKeys.insert(key)
                    for name in allConfigurations {
                        values["\(key)[config=\(name)]"] = name == configuration ? value : originalValue
                    }
                } else {
                    values["\(key)[config=\(configuration)]"] = value
                }
            } else {
                values[key] = value
                for name in allConfigurations where settings["\(key)[config=\(name)]"] != nil {
                    values["\(key)[config=\(name)]"] = value
                }
            }
        }
        var edits: [(Range<String.Index>, String)] = []
        for key in removeBaseKeys {
            guard let memberRange = settingsNode.members[key] else {
                throw IdentityError(message: "Cannot locate the selected application's setting safely.")
            }
            edits.append((memberRange, ""))
            // Leave comments around the deleted member untouched. A previous
            // member's trailing comma is valid JSON5 when this was the last one.
            if let comma = settingsNode.followingCommas[key] { edits.append((comma, "")) }
        }
        var insertions: [String] = []
        for key in values.keys.sorted() {
            let value = Self.jsonQuoted(values[key]!)
            if let node = settingsNode.entries[key] {
                edits.append((node.range, value))
            } else {
                insertions.append("\(Self.jsonQuoted(key)): \(value)")
            }
        }
        if !insertions.isEmpty {
            let position = doc.text.index(after: settingsNode.range.lowerBound)
            let suffix = settingsNode.entries.keys.allSatisfy({ removeBaseKeys.contains($0) }) ? "" : ","
            edits.append((position..<position, "\n        " + insertions.joined(separator: ",\n        ") + suffix + "\n        "))
        }
        var result = doc.text
        for (range, replacement) in edits.sorted(by: {
            $0.0.lowerBound == $1.0.lowerBound ? $0.0.upperBound > $1.0.upperBound : $0.0.lowerBound > $1.0.lowerBound
        }) {
            result.replaceSubrange(range, with: replacement)
        }
        let data = Data(result.utf8)
        guard let updated = XcodeProjectDiscovery.decodeModernProject(data: data),
              let updatedTargets = updated["targets"] as? [[String: Any]],
              updatedTargets.indices.contains(targetIndex),
              let updatedSettings = updatedTargets[targetIndex]["build-settings"] as? [String: Any],
              values.allSatisfy({ updatedSettings[$0.key] as? String == $0.value }),
              removeBaseKeys.allSatisfy({ updatedSettings[$0] == nil }) else {
            throw IdentityError(message: "The Xcode project update could not be verified. No settings were changed.")
        }
        for name in allConfigurations {
            var before = XcodeProjectDiscovery.resolveModernConfigurationSettings(projectSettings, configuration: name)
            before.merge(XcodeProjectDiscovery.resolveModernConfigurationSettings(settings, configuration: name)) { _, target in target }
            var after = XcodeProjectDiscovery.resolveModernConfigurationSettings(projectSettings, configuration: name)
            after.merge(XcodeProjectDiscovery.resolveModernConfigurationSettings(updatedSettings, configuration: name)) { _, target in target }
            for (key, value) in replacements {
                let selected = configuration == nil || configuration == name
                let expected = selected ? value : before[key] as? String
                guard after[key] as? String == expected else {
                    throw IdentityError(message: "The Xcode project's effective configuration could not be verified. No settings were changed.")
                }
            }
        }
        guard try Data(contentsOf: doc.url) == Data(doc.text.utf8) else {
            throw IdentityError(message: "The Xcode project changed during this update. Retry after saving Xcode changes.")
        }
        if !dryRun { try data.write(to: doc.url, options: .atomic) }
        return data
    }

    private static func jsonQuoted(_ value: String) -> String {
        // JSONEncoder also escapes control characters in configuration names.
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    static func validateResolvedBuildSettings(_ data: Data, targetName: String, expectedBundleID: String, projectURL: URL? = nil) throws {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw IdentityError(message: "Could not inspect the selected scheme's resolved build settings.")
        }
        let targets = entries.filter { $0["target"] as? String == targetName }
        guard targets.count == 1, let settings = targets.first?["buildSettings"] as? [String: Any],
              let identifier = settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String,
              identifier == expectedBundleID,
              settings["PRODUCT_TYPE"] as? String == "com.apple.product-type.application" else {
            throw IdentityError(message: "The selected scheme's resolved bundle ID does not match '\(expectedBundleID)'. Check the app target, configuration and xcconfig settings in Xcode.")
        }
        if let projectURL {
            guard let path = settings["PROJECT_FILE_PATH"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath() == projectURL.resolvingSymlinksInPath() else {
                throw IdentityError(message: "The selected scheme resolves to a different Xcode project. Choose an unambiguous workspace and scheme.")
            }
        }
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Source ranges for an OpenStep plist. Semantic interpretation is delegated to
/// Foundation; these ranges only let us preserve comments and unrelated objects.
private struct OpenStepRanges {
    struct Node {
        var range: Range<String.Index>
        var entries: [String: Node] = [:]
    }
    let text: String
    var index: String.Index
    init(_ text: String) { self.text = text; index = text.startIndex }

    mutating func parse() throws -> Node {
        try skipTrivia()
        let start = index
        guard index < text.endIndex else { throw invalid() }
        if text[index] == "{" {
            advance()
            var entries: [String: Node] = [:]
            while true {
                try skipTrivia()
                guard index < text.endIndex else { throw invalid() }
                if text[index] == "}" { advance(); return Node(range: start..<index, entries: entries) }
                let key = try token()
                try consume("=")
                let value = try parse()
                try consume(";")
                guard entries[key] == nil else { throw invalid() }
                entries[key] = value
            }
        }
        if text[index] == "(" {
            advance()
            while true {
                try skipTrivia()
                guard index < text.endIndex else { throw invalid() }
                if text[index] == ")" { advance(); return Node(range: start..<index) }
                _ = try parse()
                try skipTrivia()
                if index < text.endIndex && text[index] == "," { advance() }
            }
        }
        _ = try token()
        return Node(range: start..<index)
    }

    mutating func token() throws -> String {
        try skipTrivia()
        guard index < text.endIndex else { throw invalid() }
        let start = index
        if text[index] == "\"" {
            advance()
            var escaped = false
            while index < text.endIndex {
                let ch = text[index]; advance()
                if ch == "\"" && !escaped {
                    let literal = String(text[start..<index])
                    let wrapper = "{ key = \(literal); }"
                    guard let dict = try PropertyListSerialization.propertyList(from: Data(wrapper.utf8), format: nil) as? [String: String], let key = dict["key"] else { throw invalid() }
                    return key
                }
                escaped = ch == "\\" && !escaped
            }
            throw invalid()
        }
        while index < text.endIndex && !text[index].isWhitespace && !"{}()=;,".contains(text[index]) { advance() }
        guard index > start else { throw invalid() }
        return String(text[start..<index])
    }

    mutating func consume(_ expected: Character) throws {
        try skipTrivia()
        guard index < text.endIndex, text[index] == expected else { throw invalid() }
        advance()
    }
    mutating func skipTrivia() throws {
        while index < text.endIndex {
            if text[index].isWhitespace { advance(); continue }
            if text[index...].hasPrefix("//") {
                while index < text.endIndex && text[index] != "\n" { advance() }
            } else if text[index...].hasPrefix("/*") {
                guard let end = text[index...].range(of: "*/") else { throw invalid() }
                index = end.upperBound
            } else { return }
        }
    }
    mutating func advance() { index = text.index(after: index) }
    func invalid() -> XcodeProjectIdentityEditor.IdentityError {
        .init(message: "Unsupported Xcode project syntax. No settings were changed; edit the application target in Xcode.")
    }
}
