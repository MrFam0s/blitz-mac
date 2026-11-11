import Foundation
import Testing
@testable import Blitz

@Suite struct ProjectReleaseTargetsTests {
    private let shared = ProjectStoreBinding(appId: "123", accountKey: "issuer:key", sku: "Shared-App",
        bundleIdentifier: "org.example.SharedApp")
    private func metadata() -> BlitzProjectMetadata {
        let targets = [
            ProjectReleaseTarget(id: "ios", name: "iPhone und iPad", platform: .iOS,
                bundleIdentifier: shared.bundleIdentifier, buildSettings: .init(scheme: "Phone", configuration: "Release"), storeBinding: shared),
            ProjectReleaseTarget(id: "mac", name: "Mac", platform: .macOS,
                bundleIdentifier: shared.bundleIdentifier, buildSettings: .init(scheme: "Mac", configuration: "Store"), storeBinding: shared)
        ]
        return BlitzProjectMetadata(name: "Shared App", type: .swift, createdAt: Date(timeIntervalSince1970: 123),
            simulatorUDID: "sim", teamId: "team", releaseTargets: targets, selectedReleaseTargetId: "ios")
    }

    @Test func legacyMigrationKeepsExactIdentityAndStableTarget() throws {
        let raw = Data(#"{"name":"ClubBundle","type":"swift","platform":"macOS","bundleIdentifier":"org.amosystems.ClubBundle","buildSettings":{"scheme":"Mac","configuration":"Release"}}"#.utf8)
        var old = try JSONDecoder().decode(BlitzProjectMetadata.self, from: raw)
        #expect(old.releaseTargets == nil)
        #expect(try old.resolveReleaseTarget(id: nil).id == "legacy")
        old.materializeReleaseTargets()
        let again = try JSONDecoder().decode(BlitzProjectMetadata.self, from: JSONEncoder().encode(old))
        #expect(again.selectedReleaseTargetId == "legacy")
        #expect(again.bundleIdentifier == "org.amosystems.ClubBundle")
        #expect(again.platform == .macOS)
        #expect(again.buildSettings?.scheme == "Mac")
        #expect(again.resolvedReleaseTargets.count == 1)
        #expect(again.selectedReleaseTarget?.storeBinding == nil)
    }

    @Test func sharedRecordTargetsRoundtripAndSwitchWithoutMutatingIdentity() throws {
        var value = metadata()
        let originals = value.resolvedReleaseTargets
        try value.selectReleaseTarget(id: "mac")
        #expect(value.platform == .macOS)
        #expect(value.buildSettings?.scheme == "Mac")
        #expect(value.bundleIdentifier == shared.bundleIdentifier)
        #expect(value.resolvedReleaseTargets == originals)
        let roundtrip = try JSONDecoder().decode(BlitzProjectMetadata.self, from: JSONEncoder().encode(value))
        #expect(roundtrip.resolvedReleaseTargets == originals)
        #expect(roundtrip.selectedReleaseTargetId == "mac")
        #expect(roundtrip.createdAt == value.createdAt)
        #expect(roundtrip.simulatorUDID == "sim")
        #expect(roundtrip.teamId == "team")
        #expect(throws: ProjectReleaseTargetError.self) { try roundtrip.resolveReleaseTarget(id: nil) }
        #expect(try roundtrip.resolveReleaseTarget(id: "ios").platform == .iOS)
    }

    @Test func separateStoreTargetsKeepDistinctBundleIDsAndSKU() throws {
        var value = metadata()
        let separate = ProjectStoreBinding(appId: "456", accountKey: "issuer:key", sku: "Separate-Mac",
            bundleIdentifier: "org.example.SeparateMac")
        try value.upsertReleaseTarget(ProjectReleaseTarget(id: "separate", platform: .macOS,
            bundleIdentifier: separate.bundleIdentifier, buildSettings: .init(scheme: "Separate"), storeBinding: separate))
        #expect(value.resolvedReleaseTargets.count == 3)
        #expect(value.bundleIdentifier == "org.example.SeparateMac")
        #expect(value.releaseTarget(id: "ios")?.storeBinding?.sku == "Shared-App")
        #expect(value.selectedReleaseTarget?.storeBinding?.sku == "Separate-Mac")
        #expect(value.selectedReleaseTarget?.storeBinding?.appId == "456")
    }

    @Test func ambiguousOrInvalidSelectionCannotDecodeAsStaleScalarTarget() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata())) as? [String: Any])
        object["selectedReleaseTargetId"] = nil
        for badSelection in [Optional<String>.none, "missing"] {
            object["selectedReleaseTargetId"] = badSelection
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: Error.self) { try JSONDecoder().decode(BlitzProjectMetadata.self, from: data) }
        }
        object["selectedReleaseTargetId"] = "mac"
        object["bundleIdentifier"] = "org.example.Stale"
        object["platform"] = "iOS"
        let decoded = try JSONDecoder().decode(BlitzProjectMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.bundleIdentifier == shared.bundleIdentifier)
        #expect(decoded.platform == .macOS)
        #expect(decoded.buildSettings?.scheme == "Mac")
    }

    @Test func boundIdentityChangesCannotDropBindingOrPersist() throws {
        var value = metadata()
        value.bundleIdentifier = "org.example.Replacement"
        #expect(value.releaseTarget(id: "ios")?.storeBinding == shared)
        #expect(value.releaseTarget(id: "ios")?.bundleIdentifier == shared.bundleIdentifier)
        #expect(throws: ProjectReleaseTargetError.self) { try value.validateReleaseTargetConfiguration() }
        var changedTarget = try #require(value.releaseTarget(id: "ios"))
        changedTarget.bundleIdentifier = "org.example.Replacement"
        changedTarget.storeBinding = nil
        #expect(throws: ProjectReleaseTargetError.self) { try value.upsertReleaseTarget(changedTarget) }
    }

    @Test func reimportSelectsExplicitTargetAndPreservesOtherTargets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blitz-target-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ProjectRepository(baseDirectory: directory)
        let original = metadata()
        try repository.writeMetadataToDirectory(directory, metadata: original)
        #expect(throws: ProjectReleaseTargetError.self) {
            try repository.metadataForImport(directory: directory, type: .swift, platform: .macOS,
                selectedBundleID: shared.bundleIdentifier)
        }
        let imported = try repository.metadataForImport(directory: directory, type: .swift, platform: .macOS,
            selectedBundleID: shared.bundleIdentifier, releaseTargetId: "mac")
        #expect(imported.selectedReleaseTargetId == "mac")
        #expect(imported.resolvedReleaseTargets == original.resolvedReleaseTargets)
        #expect(imported.name == original.name)
        let added = try repository.metadataForImport(directory: directory, type: .swift, platform: .macOS,
            selectedBundleID: "org.example.SecondApp", addingReleaseTarget: true,
            selectedBuildSettings: .init(scheme: "SecondApp", configuration: "Release"))
        #expect(added.resolvedReleaseTargets.count == 3)
        #expect(added.releaseTarget(id: "ios") == original.releaseTarget(id: "ios"))
        #expect(added.selectedReleaseTarget?.storeBinding == nil)
        #expect(throws: ProjectReleaseTargetError.self) {
            try repository.metadataForImport(directory: directory, type: .swift, platform: .iOS,
                selectedBundleID: "org.example.Wrong", releaseTargetId: "ios")
        }
    }

    @Test func targetDiscoveryReadsApplicationConfigurationsNotUnrelatedMacSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blitz-target-discovery-\(UUID().uuidString)")
        let project = directory.appendingPathComponent("Shared.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let object: [String: Any] = ["rootObject": "project", "objects": [
            "project": ["isa": "PBXProject", "buildConfigurationList": "global"],
            "global": ["buildConfigurations": ["globalRelease"]],
            "globalRelease": ["name": "Release", "buildSettings": ["MACOSX_DEPLOYMENT_TARGET": "14.0"]],
            "phone": ["isa": "PBXNativeTarget", "productType": "com.apple.product-type.application", "name": "Phone", "buildConfigurationList": "phoneConfigs"],
            "phoneConfigs": ["buildConfigurations": ["phoneRelease"]],
            "phoneRelease": ["name": "Release", "buildSettings": ["SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.SharedApp"]],
            "mac": ["isa": "PBXNativeTarget", "productType": "com.apple.product-type.application", "name": "Mac", "buildConfigurationList": "macConfigs"],
            "macConfigs": ["buildConfigurations": ["macRelease"]],
            "macRelease": ["name": "Release", "buildSettings": ["SDKROOT": "macosx", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.SharedApp"]],
            "test": ["isa": "PBXNativeTarget", "productType": "com.apple.product-type.bundle.unit-test", "name": "Tests", "buildConfigurationList": "macConfigs"]
        ]]
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            .write(to: project.appendingPathComponent("project.pbxproj"))
        let targets = ProjectReleaseTargetDiscovery.discover(in: directory)
        #expect(targets.count == 2)
        #expect(targets.first { $0.name == "Phone" }?.platform == .iOS)
        #expect(targets.first { $0.name == "Mac" }?.platform == .macOS)
        #expect(targets.allSatisfy { $0.bundleIdentifier == "org.example.SharedApp" })
    }
    @Test func confirmedNewRecordIsInvalidatedByTargetBundleOrBindingChange() throws {
        let identity = AppCreationIdentity(appName: "Shared App", bundleId: "org.example.SharedApp", sku: "Shared-App",
            platform: .iOS, primaryLocale: "en-US")
        var value = BlitzProjectMetadata(name: "Local", type: .swift, platform: .iOS,
            bundleIdentifier: "org.example.Placeholder")
        value.materializeReleaseTargets()
        #expect(try identity.validateProjectTarget(value, targetId: "legacy", registrationComplete: false) == "legacy")
        #expect(throws: Error.self) { try identity.validateProjectTarget(value, targetId: "legacy", registrationComplete: true) }
        value.bundleIdentifier = identity.bundleId
        #expect(try identity.validateProjectTarget(value, targetId: "legacy", registrationComplete: true) == "legacy")
        #expect(throws: Error.self) { try identity.validateProjectTarget(value, targetId: "other", registrationComplete: true) }
        var bound = try #require(value.selectedReleaseTarget)
        bound.storeBinding = shared
        try value.upsertReleaseTarget(bound)
        #expect(throws: Error.self) { try identity.validateProjectTarget(value, targetId: "legacy", registrationComplete: true) }
    }

    @Test func catalystDestinationIsDistinctFromIOSOnMacAvailability() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blitz-catalyst-discovery-\(UUID().uuidString)")
        let project = directory.appendingPathComponent("Phone.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for catalyst in [false, true] {
            let settings: [String: Any] = ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                "SUPPORTS_MACCATALYST": catalyst ? "YES" : "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "YES",
                "DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER": "YES", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.Phone"]
            let object: [String: Any] = ["objects": [
                "app": ["isa": "PBXNativeTarget", "productType": "com.apple.product-type.application", "name": "Phone", "buildConfigurationList": "configs"],
                "configs": ["buildConfigurations": ["release"]],
                "release": ["name": "Release", "buildSettings": settings]
            ]]
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
                .write(to: project.appendingPathComponent("project.pbxproj"))
            let targets = ProjectReleaseTargetDiscovery.discover(in: directory)
            #expect(targets.count == (catalyst ? 2 : 1))
            #expect(targets.first { $0.platform == .iOS }?.destination == "generic/platform=iOS")
            if catalyst {
                let mac = try #require(targets.first { $0.platform == .macOS })
                #expect(mac.destination == "generic/platform=macOS,variant=Mac Catalyst")
                // A derived identifier must be resolved by Xcode/user, never fabricated.
                #expect(mac.bundleIdentifier == nil)
            }
        }
    }

    @Test func targetIDsMatchImmutableCLIIdentifiers() throws {
        var value = metadata()
        for id in ["", "contains space", "path/part", "mác", String(repeating: "x", count: 129)] {
            #expect(throws: ProjectReleaseTargetError.self) {
                try value.upsertReleaseTarget(ProjectReleaseTarget(id: id, platform: .macOS,
                    bundleIdentifier: "org.example.Other"))
            }
        }
        #expect(ProjectReleaseTarget.validID("legacy"))
        #expect(ProjectReleaseTarget.validID(UUID().uuidString))
    }

}
