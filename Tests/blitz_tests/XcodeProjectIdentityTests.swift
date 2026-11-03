// Added for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation
import Testing
@testable import Blitz

private struct IdentityFixture {
    let root: URL
    var project: URL { root.appendingPathComponent("Example.xcodeproj") }
    var file: URL { project.appendingPathComponent("project.pbxproj") }

    init(secondApp: Bool = false, conditionalID: Bool = false, sharedConfiguration: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BlitzIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let text = """
        // !$*UTF8*$!
        {
            archiveVersion = 1; objectVersion = 56;
            objects = {
                /* App IDs must retain their original case. */
                APP = { isa = PBXNativeTarget; name = MainApp; productType = "com.apple.product-type.application"; buildConfigurationList = APP_CONFIGS; };
                WIDGET = { isa = PBXNativeTarget; name = Widget; productType = "com.apple.product-type.app-extension"; buildConfigurationList = WIDGET_CONFIGS; };
                TESTS = { isa = PBXNativeTarget; name = MainAppTests; productType = "com.apple.product-type.bundle.unit-test"; buildConfigurationList = TEST_CONFIGS; };
                \(secondApp ? "OTHER = { isa = PBXNativeTarget; name = AnotherApp; productType = \"com.apple.product-type.application\"; buildConfigurationList = OTHER_CONFIGS; };" : "")
                APP_CONFIGS = { isa = XCConfigurationList; buildConfigurations = ( APP_DEBUG, APP_RELEASE, ); };
                WIDGET_CONFIGS = { isa = XCConfigurationList; buildConfigurations = ( WIDGET_RELEASE, ); };
                TEST_CONFIGS = { isa = XCConfigurationList; buildConfigurations = ( \(sharedConfiguration ? "APP_RELEASE" : "TEST_RELEASE"), ); };
                OTHER_CONFIGS = { isa = XCConfigurationList; buildConfigurations = ( OTHER_RELEASE, ); };
                APP_DEBUG = { isa = XCBuildConfiguration; name = Debug; buildSettings = { PRODUCT_BUNDLE_IDENTIFIER = org.example.MainApp.Debug; }; };
                APP_RELEASE = { isa = XCBuildConfiguration; name = Release; buildSettings = { PRODUCT_BUNDLE_IDENTIFIER = "$(APP_ID)"; OTHER_SETTING = "Keep /* comment */ ; value"; \(conditionalID ? "\"PRODUCT_BUNDLE_IDENTIFIER[sdk=iphoneos*]\" = org.example.Conditional;" : "") }; };
                WIDGET_RELEASE = { isa = XCBuildConfiguration; name = Release; buildSettings = { PRODUCT_BUNDLE_IDENTIFIER = org.example.MainApp.Widget; DEVELOPMENT_TEAM = OLD_TEAM; }; };
                TEST_RELEASE = { isa = XCBuildConfiguration; name = Release; buildSettings = { PRODUCT_BUNDLE_IDENTIFIER = org.example.MainAppTests; }; };
                OTHER_RELEASE = { isa = XCBuildConfiguration; name = Release; buildSettings = { PRODUCT_BUNDLE_IDENTIFIER = org.example.AnotherApp; }; };
                PROJECT_RELEASE = { isa = XCBuildConfiguration; name = Release; buildSettings = { APP_ID = org.example.MainApp; DEVELOPMENT_TEAM = OLD_TEAM; }; };
                PROJECT_CONFIGS = { isa = XCConfigurationList; buildConfigurations = ( PROJECT_RELEASE, ); };
                PROJECT = { isa = PBXProject; targets = ( APP, WIDGET, TESTS, ); buildConfigurationList = PROJECT_CONFIGS; };
            };
            rootObject = PROJECT;
        }
        """
        try Data(text.utf8).write(to: file)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func objects() throws -> [String: [String: Any]] {
        let dict = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as! [String: Any]
        return dict["objects"] as! [String: [String: Any]]
    }
    func scheme(name: String, targetID: String, archive: Bool = true, projectReference: String = "Example.xcodeproj") throws {
        let folder = project.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme><BuildAction><BuildActionEntries>
          <BuildActionEntry buildForArchiving="\(archive ? "YES" : "NO")"><BuildableReference BlueprintIdentifier="\(targetID)" ReferencedContainer="container:\(projectReference)"/></BuildActionEntry>
        </BuildActionEntries></BuildAction></Scheme>
        """
        try Data(xml.utf8).write(to: folder.appendingPathComponent(name + ".xcscheme"))
    }
}

@Test func xcodeIdentityChangesOnlySelectedAppConfigurationAndPreservesSource() throws {
    let fixture = try IdentityFixture()
    defer { fixture.remove() }
    let before = try fixture.objects()
    try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.amosystems.ClubBundle", configuration: "Release", teamID: "NEW_TEAM")
    let after = try fixture.objects()
    let settings = after["APP_RELEASE"]?["buildSettings"] as! [String: String]
    #expect(settings["PRODUCT_BUNDLE_IDENTIFIER"] == "org.amosystems.ClubBundle")
    #expect(settings["CODE_SIGN_STYLE"] == "Automatic")
    #expect(settings["DEVELOPMENT_TEAM"] == "NEW_TEAM")
    #expect(settings["OTHER_SETTING"] == "Keep /* comment */ ; value")
    for id in ["APP_DEBUG", "WIDGET_RELEASE", "TEST_RELEASE", "OTHER_RELEASE", "PROJECT_RELEASE"] {
        #expect(NSDictionary(dictionary: after[id]!).isEqual(to: before[id]!))
    }
    #expect(try String(contentsOf: fixture.file, encoding: .utf8).contains("/* App IDs must retain their original case. */"))
}

@Test func xcodeIdentityAmbiguousApplicationsAndWrongConfigurationDoNotMutate() throws {
    let fixture = try IdentityFixture(secondApp: true)
    defer { fixture.remove() }
    let original = try Data(contentsOf: fixture.file)
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.New")
    }
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.New", scheme: "MainApp", configuration: "Missing")
    }
    #expect(try Data(contentsOf: fixture.file) == original)
}

@Test func xcodeIdentityExplicitSchemeSelectsIntendedAppAmongSeveral() throws {
    let fixture = try IdentityFixture(secondApp: true)
    defer { fixture.remove() }
    try fixture.scheme(name: "Store Release", targetID: "OTHER")
    let before = try fixture.objects()
    try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.Second", scheme: "Store Release", configuration: "Release")
    let after = try fixture.objects()
    #expect((after["OTHER_RELEASE"]?["buildSettings"] as? [String: String])?["PRODUCT_BUNDLE_IDENTIFIER"] == "org.example.Second")
    #expect(NSDictionary(dictionary: after["APP_RELEASE"]!).isEqual(to: before["APP_RELEASE"]!))
}

@Test func xcodeIdentityConditionalAndSharedConfigurationsDoNotMutate() throws {
    for fixture in [try IdentityFixture(conditionalID: true), try IdentityFixture(sharedConfiguration: true)] {
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.file)
        #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
            try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.New")
        }
        #expect(try Data(contentsOf: fixture.file) == original)
    }
}

@Test func xcodeIdentityPreflightAndInvalidIdentifierNeverWrite() throws {
    let fixture = try IdentityFixture()
    defer { fixture.remove() }
    let original = try Data(contentsOf: fixture.file)
    try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.New", teamID: "TEAM", dryRun: true)
    #expect(try Data(contentsOf: fixture.file) == original)
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.New\nOTHER = value;")
    }
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.New\n")
    }
    #expect(try Data(contentsOf: fixture.file) == original)
}

@Test func xcodeIdentityResolvedBuildRejectsOverridesAndWrongProjects() throws {
    let fixture = try IdentityFixture()
    defer { fixture.remove() }
    func data(bundle: String, path: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            ["target": "Widget", "buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": "org.example.Widget", "PRODUCT_TYPE": "com.apple.product-type.app-extension"]],
            ["target": "MainApp", "buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": bundle, "PRODUCT_TYPE": "com.apple.product-type.application", "PROJECT_FILE_PATH": path ?? fixture.project.path]]
        ])
    }
    try XcodeProjectIdentityEditor.validateResolvedBuildSettings(data(bundle: "org.amosystems.ClubBundle"), targetName: "MainApp", expectedBundleID: "org.amosystems.ClubBundle", projectURL: fixture.project)
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try XcodeProjectIdentityEditor.validateResolvedBuildSettings(data(bundle: "org.example.Override"), targetName: "MainApp", expectedBundleID: "org.amosystems.ClubBundle")
    }
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try XcodeProjectIdentityEditor.validateResolvedBuildSettings(data(bundle: "org.amosystems.ClubBundle", path: "/tmp/Unrelated.xcodeproj"), targetName: "MainApp", expectedBundleID: "org.amosystems.ClubBundle", projectURL: fixture.project)
    }
}

@Test func xcodeIdentitySchemeResolvesFullPathForSameNamedProjects() throws {
    let fixture = try IdentityFixture()
    defer { fixture.remove() }
    let ios = fixture.root.appendingPathComponent("ios")
    try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: false)
    let nestedProject = ios.appendingPathComponent("Example.xcodeproj")
    try FileManager.default.copyItem(at: fixture.project, to: nestedProject)
    try fixture.scheme(name: "NestedApp", targetID: "APP", projectReference: "ios/Example.xcodeproj")
    let original = try Data(contentsOf: fixture.file)
    try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.Nested", scheme: "NestedApp", configuration: "Release")
    #expect(try Data(contentsOf: fixture.file) == original)
    let changed = try String(contentsOf: nestedProject.appendingPathComponent("project.pbxproj"), encoding: .utf8)
    #expect(changed.contains("PRODUCT_BUNDLE_IDENTIFIER = \"org.example.Nested\""))
}
