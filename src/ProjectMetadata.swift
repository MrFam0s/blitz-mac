import Foundation

/// Target platform for a project
enum ProjectPlatform: String, Codable, Sendable, CaseIterable {
    case iOS
    case macOS
}

/// Represents the `.blitz/project.json` metadata file
struct BlitzProjectMetadata: Codable, Sendable {
    var name: String
    var type: ProjectType
    var platform: ProjectPlatform? { didSet { updateSelectedTargetProjection() } }
    var bundleIdentifier: String? { didSet { updateSelectedTargetProjection() } }
    var createdAt: Date?
    var lastOpenedAt: Date?
    var simulatorUDID: String?
    var buildSettings: BuildSettings? { didSet { updateSelectedTargetProjection() } }
    var teamId: String?
    var releaseTargets: [ProjectReleaseTarget]?
    var selectedReleaseTargetId: String?

    init(
        name: String,
        type: ProjectType,
        platform: ProjectPlatform? = nil,
        bundleIdentifier: String? = nil,
        createdAt: Date? = nil,
        lastOpenedAt: Date? = nil,
        simulatorUDID: String? = nil,
        buildSettings: BuildSettings? = nil,
        teamId: String? = nil,
        releaseTargets: [ProjectReleaseTarget]? = nil,
        selectedReleaseTargetId: String? = nil
    ) {
        self.name = name
        self.type = type
        self.platform = platform
        self.bundleIdentifier = bundleIdentifier
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.simulatorUDID = simulatorUDID
        self.buildSettings = buildSettings
        self.teamId = teamId
        self.releaseTargets = releaseTargets
        self.selectedReleaseTargetId = selectedReleaseTargetId
        if let target = selectedReleaseTarget {
            self.selectedReleaseTargetId = nil
            self.platform = target.platform
            self.bundleIdentifier = target.bundleIdentifier
            self.buildSettings = target.buildSettings
            self.selectedReleaseTargetId = selectedReleaseTargetId ?? (releaseTargets == nil ? nil : target.id)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, platform, bundleIdentifier, createdAt, lastOpenedAt, simulatorUDID, buildSettings, teamId
        case releaseTargets, selectedReleaseTargetId
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        type = try values.decode(ProjectType.self, forKey: .type)
        platform = try values.decodeIfPresent(ProjectPlatform.self, forKey: .platform)
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
        lastOpenedAt = try values.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        simulatorUDID = try values.decodeIfPresent(String.self, forKey: .simulatorUDID)
        buildSettings = try values.decodeIfPresent(BuildSettings.self, forKey: .buildSettings)
        teamId = try values.decodeIfPresent(String.self, forKey: .teamId)
        releaseTargets = try values.decodeIfPresent([ProjectReleaseTarget].self, forKey: .releaseTargets)
        selectedReleaseTargetId = try values.decodeIfPresent(String.self, forKey: .selectedReleaseTargetId)
        if let releaseTargets {
            guard !releaseTargets.isEmpty, Set(releaseTargets.map(\.id)).count == releaseTargets.count,
                  let selected = selectedReleaseTarget else { throw ProjectReleaseTargetError.ambiguous }
            try selectReleaseTarget(id: selected.id)
            try validateReleaseTargetConfiguration()
        }
    }

    /// Resolved platform — defaults to .iOS for existing projects without a platform field.
    var resolvedPlatform: ProjectPlatform {
        selectedReleaseTarget?.platform ?? platform ?? .iOS
    }
}

enum ProjectType: String, Codable, Sendable, CaseIterable {
    case reactNative = "react-native"
    case swift
    case flutter
}

struct BuildSettings: Codable, Equatable, Sendable {
    var scheme: String?
    var configuration: String?
    var destination: String?

    init(scheme: String? = nil, configuration: String? = nil, destination: String? = nil) {
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
    }
}

/// A Store record can be shared by native iOS and macOS release targets. These
/// are public identifiers, never credentials; verify them against Apple on use.
struct ProjectStoreBinding: Codable, Equatable, Sendable {
    var appId: String
    var accountKey: String
    var sku: String?
    var bundleIdentifier: String
}

struct ProjectReleaseTarget: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String?
    var platform: ProjectPlatform
    var bundleIdentifier: String?
    var buildSettings: BuildSettings?
    var storeBinding: ProjectStoreBinding?

    init(id: String = UUID().uuidString, name: String? = nil, platform: ProjectPlatform,
         bundleIdentifier: String? = nil, buildSettings: BuildSettings? = nil,
         storeBinding: ProjectStoreBinding? = nil) {
        self.id = id; self.name = name; self.platform = platform
        self.bundleIdentifier = bundleIdentifier; self.buildSettings = buildSettings
        self.storeBinding = storeBinding
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    var displayName: String {
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.flatMap { $0.isEmpty ? nil : $0 } ?? platform.rawValue
    }
}

enum ProjectReleaseTargetError: LocalizedError {
    case missing, ambiguous, invalid, duplicate, boundIdentity
    var errorDescription: String? {
        switch self {
        case .missing: return "Das Veröffentlichungsziel wurde nicht gefunden. Bitte das Ziel erneut auswählen."
        case .ambiguous: return "Dieses Projekt hat mehrere Veröffentlichungsziele. Bitte die genaue releaseTargetId angeben."
        case .invalid: return "Das Veröffentlichungsziel enthält widersprüchliche Store- oder Projektkennungen."
        case .duplicate: return "Dieses Veröffentlichungsziel ist bereits vorhanden. Bitte das vorhandene Ziel auswählen."
        case .boundIdentity: return "Die Bundle-ID einer bestätigten Store-Zuordnung kann nicht geändert werden. Lege dafür ein separates Veröffentlichungsziel an."
        }
    }
}

extension BlitzProjectMetadata {
    /// Deterministic legacy identity avoids changing the target when an old
    /// project is read before its first migration write.
    var resolvedReleaseTargets: [ProjectReleaseTarget] {
        if let releaseTargets { return releaseTargets }
        return [ProjectReleaseTarget(id: "legacy", platform: platform ?? .iOS,
            bundleIdentifier: bundleIdentifier, buildSettings: buildSettings)]
    }

    var selectedReleaseTarget: ProjectReleaseTarget? {
        if let selectedReleaseTargetId {
            return resolvedReleaseTargets.first { $0.id == selectedReleaseTargetId }
        }
        return resolvedReleaseTargets.count == 1 ? resolvedReleaseTargets.first : nil
    }

    func releaseTarget(id: String) -> ProjectReleaseTarget? {
        resolvedReleaseTargets.first { $0.id == id }
    }

    /// CLI callers must not inherit the currently selected UI target.
    func resolveReleaseTarget(id: String?) throws -> ProjectReleaseTarget {
        if let id {
            guard let target = releaseTarget(id: id) else { throw ProjectReleaseTargetError.missing }
            return target
        }
        guard resolvedReleaseTargets.count == 1, let target = resolvedReleaseTargets.first else {
            throw ProjectReleaseTargetError.ambiguous
        }
        return target
    }

    mutating func materializeReleaseTargets() {
        guard releaseTargets == nil else { return }
        let targets = resolvedReleaseTargets
        releaseTargets = targets
        selectedReleaseTargetId = targets.first?.id
    }

    mutating func selectReleaseTarget(id: String) throws {
        guard let target = releaseTarget(id: id) else { throw ProjectReleaseTargetError.missing }
        materializeReleaseTargets()
        // Set the projection before changing the selection to avoid applying old
        // scalar settings to a newly selected target through property observers.
        selectedReleaseTargetId = nil
        platform = target.platform
        bundleIdentifier = target.bundleIdentifier
        buildSettings = target.buildSettings
        selectedReleaseTargetId = id
    }

    mutating func upsertReleaseTarget(_ target: ProjectReleaseTarget, select: Bool = true) throws {
        guard ProjectReleaseTarget.validID(target.id),
              target.bundleIdentifier.map(AppCreationIdentity.validBundleID) ?? true else {
            throw ProjectReleaseTargetError.invalid
        }
        if let binding = target.storeBinding {
            guard !binding.appId.isEmpty, !binding.accountKey.isEmpty,
                  binding.bundleIdentifier == target.bundleIdentifier,
                  binding.sku.map(AppCreationIdentity.validSKU) ?? true else { throw ProjectReleaseTargetError.invalid }
        }
        materializeReleaseTargets()
        if let index = releaseTargets?.firstIndex(where: { $0.id == target.id }) {
            if let priorBinding = releaseTargets?[index].storeBinding,
               priorBinding.bundleIdentifier != target.bundleIdentifier { throw ProjectReleaseTargetError.boundIdentity }
            releaseTargets?[index] = target
        } else {
            guard !(releaseTargets ?? []).contains(where: {
                $0.platform == target.platform && $0.bundleIdentifier == target.bundleIdentifier
                    && $0.buildSettings == target.buildSettings
            }) else { throw ProjectReleaseTargetError.duplicate }
            releaseTargets?.append(target)
        }
        if select { try selectReleaseTarget(id: target.id) }
    }

    func validateReleaseTargetConfiguration() throws {
        guard !resolvedReleaseTargets.isEmpty,
              Set(resolvedReleaseTargets.map(\.id)).count == resolvedReleaseTargets.count,
              let selected = selectedReleaseTarget else { throw ProjectReleaseTargetError.ambiguous }
        for target in resolvedReleaseTargets {
            guard ProjectReleaseTarget.validID(target.id) else { throw ProjectReleaseTargetError.invalid }
            if let binding = target.storeBinding {
                guard !binding.appId.isEmpty, !binding.accountKey.isEmpty,
                      binding.bundleIdentifier == target.bundleIdentifier,
                      binding.sku.map(AppCreationIdentity.validSKU) ?? true else { throw ProjectReleaseTargetError.invalid }
            }
        }
        guard selected.bundleIdentifier == bundleIdentifier, selected.platform == (platform ?? .iOS),
              selected.buildSettings == buildSettings else { throw ProjectReleaseTargetError.boundIdentity }
    }

    /// Legacy build-setting and unbound-identity callers stay compatible. A
    /// bound target never loses its Store binding through a scalar assignment;
    /// incompatible scalar changes are rejected at the persistence boundary.
    private mutating func updateSelectedTargetProjection() {
        guard let id = selectedReleaseTargetId,
              let index = releaseTargets?.firstIndex(where: { $0.id == id }) else { return }
        if releaseTargets?[index].storeBinding != nil,
           releaseTargets?[index].bundleIdentifier != bundleIdentifier || releaseTargets?[index].platform != (platform ?? .iOS) {
            return
        }
        releaseTargets?[index].platform = platform ?? .iOS
        releaseTargets?[index].bundleIdentifier = bundleIdentifier
        releaseTargets?[index].buildSettings = buildSettings
    }
}
