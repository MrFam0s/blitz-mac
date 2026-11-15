import Foundation
import Testing
@testable import Blitz

@Suite struct XcodeProjectDiscoveryTests {
    @Test func modernJSON5FindsOnlyApplicationTargetsAndPreservesIdentity() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.writeModern("""
        {
          // Xcode's project.xcproj accepts comments and trailing commas.
          "default-configuration": "Release",
          "configurations": ["Debug", "Release",],
          "build-settings": {
            "MACOSX_DEPLOYMENT_TARGET": "27.2",
            "XROS_DEPLOYMENT_TARGET": "27.2",
          },
          "targets": [
            {
              "name": "ContactHelper", "id": "APP", "product-type": "application",
              "build-settings": {
                "PRODUCT_BUNDLE_IDENTIFIER": "org.example.ContactHelper",
                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                "SDKROOT": "auto",
                "GENERATE_INFOPLIST_FILE": "YES",
              },
            },
            {
              "name": "ContactHelperTests", "id": "UNIT", "product-type": "bundle.unit-test",
              "build-settings": {"PRODUCT_BUNDLE_IDENTIFIER": "org.example.ContactHelperTests", "SDKROOT": "macosx",},
            },
            {
              "name": "ContactHelperUITests", "id": "UI", "product-type": "bundle.ui-testing",
              "build-settings": {"PRODUCT_BUNDLE_IDENTIFIER": "org.example.ContactHelperUITests", "SDKROOT": "iphoneos",},
            },
            {
              "name": "Library", "id": "LIB", "product-type": "framework",
              "build-settings": {"PRODUCT_BUNDLE_IDENTIFIER": "org.example.Library", "SDKROOT": "macosx",},
            },
            {
              "name": "Widget", "id": "WIDGET", "product-type": "app-extension",
              "build-settings": {"PRODUCT_BUNDLE_IDENTIFIER": "org.example.Widget", "SDKROOT": "iphoneos",},
            },
          ],
        }
        """)
        // A separately stored test plist must not contaminate app discovery.
        try fixture.writePlist(["CFBundleIdentifier": "org.example.ContactHelperTests", "CFBundlePackageType": "BNDL"], at: "Tests/Info.plist")

        let targets = ProjectReleaseTargetDiscovery.discover(in: fixture.root)
        #expect(targets.count == 2)
        #expect(targets.first?.configuration == "Release")
        #expect(Set(targets.map(\.configuration)) == ["Debug", "Release"])
        #expect(Set(targets.map(\.id)).count == 2)
        #expect(targets.allSatisfy { $0.name == "ContactHelper" && $0.platform == .iOS })
        #expect(targets.allSatisfy { $0.bundleIdentifier == "org.example.ContactHelper" })
        #expect(targets.allSatisfy { $0.destination == "generic/platform=iOS" })
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root) == ["org.example.ContactHelper"])
        #expect(ProjectMetadataHydrator().autoSelectedBundleIdentifier(projectDirectory: fixture.root) == "org.example.ContactHelper")
    }

    @Test func legacyApplicationInheritsProjectIdentifierAndIgnoresTestIdentities() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.writeLegacy(
            projectSettings: ["PRODUCT_BUNDLE_IDENTIFIER": "org.example.RealTests", "SDKROOT": "iphoneos"],
            targets: [
                .init(name: "RealTests", type: "com.apple.product-type.application", settings: [:]),
                .init(name: "UnitTests", type: "com.apple.product-type.bundle.unit-test", settings: ["PRODUCT_BUNDLE_IDENTIFIER": "org.example.UnitTests"]),
                .init(name: "UITests", type: "com.apple.product-type.bundle.ui-testing", settings: ["PRODUCT_BUNDLE_IDENTIFIER": "org.example.UITests"]),
                .init(name: "Library", type: "com.apple.product-type.framework", settings: ["PRODUCT_BUNDLE_IDENTIFIER": "org.example.Library"]),
            ]
        )
        let targets = ProjectReleaseTargetDiscovery.discover(in: fixture.root)
        #expect(targets.count == 1)
        #expect(targets.first?.name == "RealTests") // Names are not a target-type heuristic.
        #expect(targets.first?.bundleIdentifier == "org.example.RealTests")
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root) == ["org.example.RealTests"])
    }

    @Test func modernTargetBaseSettingTakesPrecedenceOverConditionalSibling() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.writeModern("""
        {
          "configurations": ["Debug", "Release"],
          "build-settings": {
            "SDKROOT": "iphoneos",
            "PRODUCT_BUNDLE_IDENTIFIER": "org.example.ProjectDefault",
            "PRODUCT_BUNDLE_IDENTIFIER[config=Release]": "org.example.ProjectRelease"
          },
          "targets": [{
            "name": "App", "id": "APP", "product-type": "application",
            "build-settings": {
              "PRODUCT_BUNDLE_IDENTIFIER": "org.example.App",
              "PRODUCT_BUNDLE_IDENTIFIER[config=Debug]": "org.example.App.Debug"
            }
          }]
        }
        """)
        let targets = ProjectReleaseTargetDiscovery.discover(in: fixture.root)
        #expect(targets.count == 2)
        #expect(targets.first { $0.configuration == "Release" }?.bundleIdentifier == "org.example.App")
        #expect(targets.first { $0.configuration == "Debug" }?.bundleIdentifier == "org.example.App")
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root) == ["org.example.App"])
        #expect(ProjectMetadataHydrator().autoSelectedBundleIdentifier(projectDirectory: fixture.root) == "org.example.App")
    }

    @Test func modernProjectBaseSettingTakesPrecedenceWhenInherited() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.writeModern("""
        {
          "configurations": ["Debug", "Release"],
          "build-settings": {
            "SDKROOT": "iphoneos",
            "PRODUCT_BUNDLE_IDENTIFIER": "org.example.Base",
            "PRODUCT_BUNDLE_IDENTIFIER[config=Release]": "org.example.Store"
          },
          "targets": [{"name": "App", "id": "APP", "product-type": "application", "build-settings": {}}]
        }
        """)
        let targets = ProjectReleaseTargetDiscovery.discover(in: fixture.root)
        #expect(targets.first { $0.configuration == "Release" }?.bundleIdentifier == "org.example.Base")
        #expect(targets.first { $0.configuration == "Debug" }?.bundleIdentifier == "org.example.Base")
    }

    @Test(arguments: [false, true]) func modernConditionalOnlyIdentitiesResolvePerConfiguration(targetOverrides: Bool) throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        let targetSettings = targetOverrides ? """
        "PRODUCT_BUNDLE_IDENTIFIER[config=Debug]": "org.example.App.Debug",
        "PRODUCT_BUNDLE_IDENTIFIER[config=Release]": "org.example.App"
        """ : ""
        try fixture.writeModern("""
        {
          "configurations": ["Debug", "Release"],
          "build-settings": {
            "SDKROOT": "iphoneos",
            "PRODUCT_BUNDLE_IDENTIFIER[config=Debug]": "org.example.Project.Debug",
            "PRODUCT_BUNDLE_IDENTIFIER[config=Release]": "org.example.Project"
          },
          "targets": [{
            "name": "App", "id": "APP", "product-type": "application",
            "build-settings": {\(targetSettings)}
          }]
        }
        """)
        let releaseID = targetOverrides ? "org.example.App" : "org.example.Project"
        let debugID = releaseID + ".Debug"
        let targets = ProjectReleaseTargetDiscovery.discover(in: fixture.root)
        #expect(targets.count == 2)
        #expect(targets.first { $0.configuration == "Release" }?.bundleIdentifier == releaseID)
        #expect(targets.first { $0.configuration == "Debug" }?.bundleIdentifier == debugID)
        #expect(Set(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root)) == [releaseID, debugID])
        #expect(ProjectMetadataHydrator().autoSelectedBundleIdentifier(projectDirectory: fixture.root) == nil)
    }

    @Test(arguments: [false, true]) func multipleApplicationIDsRequireSelection(modern: Bool) throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        let apps = [
            DiscoveryFixture.Target(name: "Phone", type: modern ? "application" : "com.apple.product-type.application",
                settings: ["SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.Phone"]),
            DiscoveryFixture.Target(name: "Mac", type: modern ? "application" : "com.apple.product-type.application",
                settings: ["SDKROOT": "macosx", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.Mac"]),
        ]
        try fixture.writeProject(modern: modern, targets: apps)
        let hydrator = ProjectMetadataHydrator()
        #expect(Set(hydrator.discoverBundleIdentifiers(projectDirectory: fixture.root)) == ["org.example.Phone", "org.example.Mac"])
        #expect(hydrator.autoSelectedBundleIdentifier(projectDirectory: fixture.root) == nil)
        let original = BlitzProjectMetadata(name: "Shared", type: .swift, platform: .iOS)
        let result = hydrator.hydrate(original, projectDirectory: fixture.root)
        #expect(result.metadata.bundleIdentifier == nil)
        #expect(!result.didChange)
    }

    @Test(arguments: [false, true]) func testOnlyProjectsDoNotProduceApplicationIDs(modern: Bool) throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.writeProject(modern: modern, targets: [
            .init(name: "UnitTests", type: modern ? "bundle.unit-test" : "com.apple.product-type.bundle.unit-test",
                settings: ["SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.UnitTests"]),
        ])
        try fixture.writePlist(["CFBundleIdentifier": "org.example.UnitTests", "CFBundlePackageType": "BNDL"], at: "Tests/Info.plist")
        #expect(ProjectReleaseTargetDiscovery.discover(in: fixture.root).isEmpty)
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root).isEmpty)
    }

    @Test(arguments: [false, true]) func unresolvedOrSDKDependentBundleIDsAreNotGuessed(modern: Bool) throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.writeProject(modern: modern, targets: [
            .init(name: "Variable", type: modern ? "application" : "com.apple.product-type.application",
                settings: ["SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": "$(APP_IDENTIFIER)", "INFOPLIST_FILE": "App/Info.plist"]),
            .init(name: "Conditional", type: modern ? "application" : "com.apple.product-type.application",
                settings: ["SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.Default",
                    "PRODUCT_BUNDLE_IDENTIFIER[sdk=iphoneos*]": "org.example.DeviceOnly"]),
        ])
        try fixture.writePlist(["CFBundleIdentifier": "org.example.StalePlist", "CFBundlePackageType": "APPL"], at: "App/Info.plist")
        let targets = ProjectReleaseTargetDiscovery.discover(in: fixture.root)
        #expect(targets.count == 2)
        #expect(targets.allSatisfy { $0.bundleIdentifier == nil })
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root).isEmpty)
    }

    @Test func bundleIdentityDoesNotRequireGuessingAnAmbiguousPlatform() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.writeProject(modern: true, targets: [
            .init(name: "App", type: "application", settings: ["PRODUCT_BUNDLE_IDENTIFIER": "org.example.ExactCase",
                "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "MACOSX_DEPLOYMENT_TARGET": "14.0"]),
        ])
        #expect(ProjectReleaseTargetDiscovery.discover(in: fixture.root).isEmpty)
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root) == ["org.example.ExactCase"])
    }

    @Test(arguments: [false, true]) func appTargetInfoPlistCanSupplyMissingIdentifier(modern: Bool) throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.writeProject(modern: modern, targets: [
            .init(name: "App", type: modern ? "application" : "com.apple.product-type.application",
                settings: ["SDKROOT": "iphoneos", "INFOPLIST_FILE": "App/Info.plist"]),
        ])
        try fixture.writePlist(["CFBundleIdentifier": "org.example.FromAppPlist"], at: "App/Info.plist")
        try fixture.writePlist(["CFBundleIdentifier": "org.example.OtherTest"], at: "Tests/Info.plist")
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root) == ["org.example.FromAppPlist"])
        let targets = ProjectReleaseTargetDiscovery.discover(in: fixture.root)
        #expect(targets.count == 1)
        #expect(targets.first?.bundleIdentifier == "org.example.FromAppPlist")
    }

    @Test func sourceOnlyInfoPlistsRequireExplicitApplicationPackageType() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.writePlist(["CFBundleIdentifier": "org.example.Standalone", "CFBundlePackageType": "APPL"], at: "App/Info.plist")
        try fixture.writePlist(["CFBundleIdentifier": "org.example.Test", "CFBundlePackageType": "BNDL"], at: "Tests/Info.plist")
        try fixture.writePlist(["CFBundleIdentifier": "org.example.Framework", "CFBundlePackageType": "FMWK"], at: "Framework/Info.plist")
        try fixture.writePlist(["CFBundleIdentifier": "org.example.Unknown"], at: "Other/Info.plist")
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root) == ["org.example.Standalone"])
    }

    @Test(arguments: [false, true]) func unresolvedExternalConfigurationCannotUseStalePlistIdentity(modern: Bool) throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        if modern {
            try fixture.writeModern("""
            {
              "configurations": ["Release"],
              "targets": [{
                "name": "App", "id": "APP", "product-type": "application",
                "base-configuration": "App.xcconfig",
                "build-settings": {"SDKROOT": "iphoneos", "INFOPLIST_FILE": "App/Info.plist"}
              }]
            }
            """)
        } else {
            try fixture.writeLegacy(targets: [.init(name: "App", type: "com.apple.product-type.application",
                settings: ["SDKROOT": "iphoneos", "INFOPLIST_FILE": "App/Info.plist"])])
            let file = fixture.root.appendingPathComponent("Example.xcodeproj/project.pbxproj")
            var document = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
            var objects = try #require(document["objects"] as? [String: [String: Any]])
            objects["release-0"]?["baseConfigurationReference"] = "xcconfig"
            objects["xcconfig"] = ["isa": "PBXFileReference", "path": "App.xcconfig"]
            document["objects"] = objects
            try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0).write(to: file)
        }
        try fixture.writePlist(["CFBundleIdentifier": "org.example.Stale", "CFBundlePackageType": "APPL"], at: "App/Info.plist")
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root).isEmpty)
        #expect(ProjectReleaseTargetDiscovery.discover(in: fixture.root).allSatisfy { $0.bundleIdentifier == nil })
    }

    @Test func conflictingOrMalformedProjectDefinitionsDoNotFallBackToUnrelatedPlists() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.writeProject(modern: true, targets: [.init(name: "App", type: "application",
            settings: ["SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.Modern"])])
        try fixture.writeLegacy(targets: [.init(name: "App", type: "com.apple.product-type.application",
            settings: ["SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.Legacy"])])
        try fixture.writePlist(["CFBundleIdentifier": "org.example.Unrelated", "CFBundlePackageType": "APPL"], at: "Other/Info.plist")
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root).isEmpty)
        #expect(ProjectReleaseTargetDiscovery.discover(in: fixture.root).isEmpty)

        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Example.xcodeproj/project.pbxproj"))
        try fixture.writeModern("{ \"targets\": [ this is incomplete")
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root).isEmpty)
        #expect(ProjectReleaseTargetDiscovery.discover(in: fixture.root).isEmpty)
    }

    @Test func legacyOrphanApplicationObjectIsNotAProjectTarget() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.writeLegacy(targets: [
            .init(name: "App", type: "com.apple.product-type.application",
                settings: ["SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.App"]),
            .init(name: "Orphan", type: "com.apple.product-type.application",
                settings: ["SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.Orphan"]),
        ])
        let file = fixture.root.appendingPathComponent("Example.xcodeproj/project.pbxproj")
        var document = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        var objects = try #require(document["objects"] as? [String: [String: Any]])
        objects["project"]?["targets"] = ["target-0"]
        document["objects"] = objects
        try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0).write(to: file)
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root) == ["org.example.App"])
        let targets = ProjectReleaseTargetDiscovery.discover(in: fixture.root)
        #expect(targets.count == 1)
        #expect(targets.first?.name == "App")
    }

    @Test func nestedProjectIsDiscoveredAndGeneratedOrDependencyCopiesAreSkipped() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        let app = DiscoveryFixture.Target(name: "App", type: "application",
            settings: ["SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.Nested"])
        try fixture.writeProject(modern: true, targets: [app], projectPath: "Sources/Apple/App.xcodeproj")
        for excluded in ["build", "DerivedData", "Pods", "node_modules", ".build", ".git"] {
            try fixture.writeProject(modern: true, targets: [.init(name: "Unrelated", type: "application",
                settings: ["SDKROOT": "macosx", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.Unrelated"])],
                projectPath: "\(excluded)/Other.xcodeproj")
        }
        let candidates = ProjectReleaseTargetDiscovery.discover(in: fixture.root)
        #expect(candidates.count == 1)
        #expect(candidates.first?.bundleIdentifier == "org.example.Nested")
        #expect(ProjectMetadataHydrator().discoverBundleIdentifiers(projectDirectory: fixture.root) == ["org.example.Nested"])
    }

    @Test func savedIdentityIsNotOverwrittenByNewProjectDiscovery() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.writeProject(modern: true, targets: [.init(name: "App", type: "application",
            settings: ["SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": "org.example.CurrentProject"])])
        let original = BlitzProjectMetadata(name: "App", type: .swift, platform: .iOS,
            bundleIdentifier: "org.example.UserSelection")
        let result = ProjectMetadataHydrator().hydrate(original, projectDirectory: fixture.root)
        #expect(result.metadata.bundleIdentifier == "org.example.UserSelection")
        #expect(!result.didChange)
    }
}

private struct DiscoveryFixture {
    struct Target {
        let name: String
        let type: String
        let settings: [String: String]
    }

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("blitz-project-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func writeModern(_ contents: String, projectPath: String = "Example.xcodeproj") throws {
        let project = root.appendingPathComponent(projectPath)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try contents.write(to: project.appendingPathComponent("project.xcproj"), atomically: true, encoding: .utf8)
    }

    func writeProject(modern: Bool, targets: [Target], projectPath: String = "Example.xcodeproj") throws {
        if modern {
            let object: [String: Any] = ["configurations": ["Release"], "default-configuration": "Release",
                "targets": targets.enumerated().map { index, target in
                    ["id": "target-\(index)", "name": target.name, "product-type": target.type, "build-settings": target.settings] as [String: Any]
                }]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try writeModern(String(decoding: data, as: UTF8.self), projectPath: projectPath)
        } else {
            try writeLegacy(targets: targets, projectPath: projectPath)
        }
    }

    func writeLegacy(projectSettings: [String: String] = [:], targets: [Target], projectPath: String = "Example.xcodeproj") throws {
        var objects: [String: Any] = [
            "project": ["isa": "PBXProject", "buildConfigurationList": "projectConfigs",
                "targets": targets.indices.map { "target-\($0)" }],
            "projectConfigs": ["isa": "XCConfigurationList", "buildConfigurations": ["projectRelease"]],
            "projectRelease": ["isa": "XCBuildConfiguration", "name": "Release", "buildSettings": projectSettings],
        ]
        for (index, target) in targets.enumerated() {
            objects["target-\(index)"] = ["isa": "PBXNativeTarget", "name": target.name,
                "productType": target.type, "buildConfigurationList": "configs-\(index)"]
            objects["configs-\(index)"] = ["isa": "XCConfigurationList", "buildConfigurations": ["release-\(index)"]]
            objects["release-\(index)"] = ["isa": "XCBuildConfiguration", "name": "Release", "buildSettings": target.settings]
        }
        let project = root.appendingPathComponent(projectPath)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["rootObject": "project", "objects": objects], format: .xml, options: 0)
        try data.write(to: project.appendingPathComponent("project.pbxproj"))
    }

    func writePlist(_ value: [String: Any], at relativePath: String) throws {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: file)
    }
}
