import Foundation
import Testing
@testable import Blitz

private struct ModernIdentityFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlitzModernIdentity-\(UUID().uuidString)")
    var project: URL { root.appendingPathComponent("Example.xcodeproj") }
    var file: URL { project.appendingPathComponent("project.xcproj") }

    init(extraSetting: String = "", secondApp: Bool = false, emptySettings: Bool = false) throws {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let settings = emptySettings ? "" : """
        // Keep the original mixed-case identity and unrelated syntax.
        'PRODUCT_BUNDLE_IDENTIFIER': 'org.example.MainApp',
        'PRODUCT_BUNDLE_IDENTIFIER[config=Debug]': 'org.example.MainApp.Debug',
        'OTHER_SETTING': 'https://example.org/*keep*/',
        \(extraSetting)
        """
        let text = """
        {
          configurations: ['Debug', 'Release',],
          'default-configuration': 'Release',
          'build-settings': {'PROJECT_VALUE': 'retain',},
          targets: [
            {id:'APP', name:'MainApp', 'product-type':'application', 'build-settings':{\(settings)}},
            {id:'TESTS', name:'MainAppTests', 'product-type':'bundle.unit-test', 'build-settings':{'PRODUCT_BUNDLE_IDENTIFIER':'org.example.MainAppTests'}},
            {id:'UITESTS', name:'MainAppUITests', 'product-type':'bundle.ui-testing', 'build-settings':{'PRODUCT_BUNDLE_IDENTIFIER':'org.example.MainAppUITests'}},
            {id:'WIDGET', name:'Widget', 'product-type':'app-extension', 'build-settings':{'PRODUCT_BUNDLE_IDENTIFIER':'org.example.Widget'}},
            \(secondApp ? "{id:'SECOND', name:'SecondApp', 'product-type':'application', 'build-settings':{'PRODUCT_BUNDLE_IDENTIFIER':'org.example.SecondApp'}}," : "")
          ],
          'unknown-future-key': { nested:[1,2,3,], },
        }
        """
        try Data(text.utf8).write(to: file)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func parsed() throws -> [String: Any] {
        try #require(XcodeProjectDiscovery.decodeModernProject(data: Data(contentsOf: file)))
    }
    func settings() throws -> [String: Any] {
        let parsed = try parsed()
        let targets = try #require(parsed["targets"] as? [[String: Any]])
        return try #require(targets.first?["build-settings"] as? [String: Any])
    }
}

@Test func modernIdentitySelectsApplicationAndUpdatesOnlyRelease() throws {
    let fixture = try ModernIdentityFixture()
    defer { fixture.remove() }
    let before = try fixture.parsed()
    let editor = XcodeProjectIdentityEditor()
    let selection = try editor.select(projectPath: fixture.root.path, configuration: "Release")
    #expect(selection.targetID == "APP")
    #expect(selection.fileURL == fixture.file)
    #expect(selection.configurationIDs == ["Release"])
    try editor.update(projectPath: fixture.root.path, bundleID: "org.amosystems.CaseKept", configuration: "Release", teamID: "TEAM")
    let settings = try fixture.settings()
    #expect(settings["PRODUCT_BUNDLE_IDENTIFIER[config=Release]"] as? String == "org.amosystems.CaseKept")
    #expect(settings["PRODUCT_BUNDLE_IDENTIFIER"] == nil)
    // Xcode previously used the unconditional base in Debug as well; the old
    // ineffective Debug override must not become effective during this edit.
    #expect(settings["PRODUCT_BUNDLE_IDENTIFIER[config=Debug]"] as? String == "org.example.MainApp")
    #expect(XcodeProjectDiscovery.resolveModernConfigurationSettings(settings, configuration: "Debug")["PRODUCT_BUNDLE_IDENTIFIER"] as? String == "org.example.MainApp")
    #expect(XcodeProjectDiscovery.resolveModernConfigurationSettings(settings, configuration: "Release")["PRODUCT_BUNDLE_IDENTIFIER"] as? String == "org.amosystems.CaseKept")
    #expect(settings["DEVELOPMENT_TEAM[config=Release]"] as? String == "TEAM")
    #expect(settings["CODE_SIGN_STYLE[config=Release]"] as? String == "Automatic")
    let after = try fixture.parsed()
    let beforeTargets = try #require(before["targets"] as? [[String: Any]])
    let afterTargets = try #require(after["targets"] as? [[String: Any]])
    for index in 1..<beforeTargets.count {
        #expect(NSDictionary(dictionary: afterTargets[index]).isEqual(to: beforeTargets[index]))
    }
    #expect(NSDictionary(dictionary: after["unknown-future-key"] as! [String: Any]).isEqual(to: before["unknown-future-key"] as! [String: Any]))
    let text = try String(contentsOf: fixture.file, encoding: .utf8)
    #expect(text.contains("// Keep the original mixed-case identity and unrelated syntax."))
    #expect(text.contains("'OTHER_SETTING': 'https://example.org/*keep*/'"))
}

@Test func modernIdentityAllConfigurationsUpdatesExistingOverrides() throws {
    let fixture = try ModernIdentityFixture()
    defer { fixture.remove() }
    try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.Updated")
    let settings = try fixture.settings()
    #expect(settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == "org.example.Updated")
    #expect(settings["PRODUCT_BUNDLE_IDENTIFIER[config=Debug]"] as? String == "org.example.Updated")
}

@Test func modernIdentitySupportsEmptySettingsAndDryRun() throws {
    let fixture = try ModernIdentityFixture(emptySettings: true)
    defer { fixture.remove() }
    let original = try Data(contentsOf: fixture.file)
    let editor = XcodeProjectIdentityEditor()
    let preview = try editor.update(projectPath: fixture.root.path, bundleID: "org.example.Updated", configuration: "Release", teamID: "TEAM", dryRun: true)
    #expect(preview != original)
    #expect(try Data(contentsOf: fixture.file) == original)
    try editor.update(projectPath: fixture.root.path, bundleID: "org.example.Updated", configuration: "Release", teamID: "TEAM")
    #expect(try fixture.settings()["PRODUCT_BUNDLE_IDENTIFIER[config=Release]"] as? String == "org.example.Updated")
}

@Test func modernIdentityRejectsSDKAndWildcardOverridesWithoutMutation() throws {
    for condition in ["sdk=iphoneos*", "config=Rel*", "config=Release][sdk=iphoneos*"] {
        let fixture = try ModernIdentityFixture(extraSetting: "'PRODUCT_BUNDLE_IDENTIFIER[\(condition)]':'org.example.Conditional',")
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.file)
        #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
            try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.Updated", configuration: "Release")
        }
        #expect(try Data(contentsOf: fixture.file) == original)
    }
}

@Test func modernIdentityRejectsAmbiguousAppOrTestScheme() throws {
    let fixture = try ModernIdentityFixture(secondApp: true)
    defer { fixture.remove() }
    let original = try Data(contentsOf: fixture.file)
    let editor = XcodeProjectIdentityEditor()
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try editor.update(projectPath: fixture.root.path, bundleID: "org.example.Updated")
    }
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try editor.update(projectPath: fixture.root.path, bundleID: "org.example.Updated", scheme: "MainAppTests")
    }
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try editor.update(projectPath: fixture.root.path, bundleID: "org.example.Updated", scheme: "MainApp", configuration: "Missing")
    }
    #expect(try Data(contentsOf: fixture.file) == original)
    try editor.update(projectPath: fixture.root.path, bundleID: "org.example.Updated", scheme: "MainApp", configuration: "Release")
    #expect(try fixture.settings()["PRODUCT_BUNDLE_IDENTIFIER[config=Release]"] as? String == "org.example.Updated")
}

@Test func modernIdentityRejectsDuplicateJSONKeysAndBothProjectFormats() throws {
    let fixture = try ModernIdentityFixture(extraSetting: "'PRODUCT_BUNDLE_IDENTIFIER':'org.example.Duplicate',")
    defer { fixture.remove() }
    let original = try Data(contentsOf: fixture.file)
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.Updated")
    }
    #expect(try Data(contentsOf: fixture.file) == original)
    try Data("{ objects = {}; }".utf8).write(to: fixture.project.appendingPathComponent("project.pbxproj"))
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try XcodeProjectIdentityEditor().select(projectPath: fixture.root.path)
    }
}

private enum ModernMetadataFailure: Error { case failed }

@Test func modernIdentityTransactionRollsBackExactJSON5AfterMetadataFailure() throws {
    let fixture = try ModernIdentityFixture()
    defer { fixture.remove() }
    let original = try Data(contentsOf: fixture.file)
    #expect(throws: ModernMetadataFailure.self) {
        try ProjectBundleIDTransaction.update(projectPath: fixture.root.path, bundleID: "org.example.Updated", scheme: "MainApp", configuration: "Release") {
            #expect(try fixture.settings()["PRODUCT_BUNDLE_IDENTIFIER[config=Release]"] as? String == "org.example.Updated")
            throw ModernMetadataFailure.failed
        }
    }
    #expect(try Data(contentsOf: fixture.file) == original)
}

@Test func modernIdentityTransactionPreservesConcurrentEditAndRejectsStaleSnapshot() throws {
    let fixture = try ModernIdentityFixture()
    defer { fixture.remove() }
    let original = try Data(contentsOf: fixture.file)
    let concurrent = original + Data("\n// Xcode saved concurrently\n".utf8)
    #expect(throws: ProjectBundleIDTransaction.Failure.self) {
        try ProjectBundleIDTransaction.update(projectPath: fixture.root.path, bundleID: "org.example.Updated", scheme: "MainApp", configuration: "Release") {
            try concurrent.write(to: fixture.file, options: .atomic)
            throw ModernMetadataFailure.failed
        }
    }
    #expect(try Data(contentsOf: fixture.file) == concurrent)
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.Updated", configuration: "Release", expectedOriginal: original)
    }
    #expect(try Data(contentsOf: fixture.file) == concurrent)
}

@Test func modernIdentityExpandsCompactBaseAndRetainsComments() throws {
    let fixture = try ModernIdentityFixture(emptySettings: true)
    defer { fixture.remove() }
    let compact = """
    {configurations:['Debug','Release'], targets:[{id:'APP',name:'MainApp','product-type':'application','build-settings':{'PRODUCT_BUNDLE_IDENTIFIER':'org.example.Original'/* retain this comment */}}]}
    """
    try Data(compact.utf8).write(to: fixture.file)
    try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.Updated", configuration: "Release")
    let settings = try fixture.settings()
    #expect(settings["PRODUCT_BUNDLE_IDENTIFIER"] == nil)
    #expect(settings["PRODUCT_BUNDLE_IDENTIFIER[config=Debug]"] as? String == "org.example.Original")
    #expect(settings["PRODUCT_BUNDLE_IDENTIFIER[config=Release]"] as? String == "org.example.Updated")
    #expect(try String(contentsOf: fixture.file, encoding: .utf8).contains("/* retain this comment */"))
}
