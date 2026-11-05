import AppKit
import Foundation
import Testing
@testable import Blitz

/// A real property-list project graph, rather than a build-setting regex fragment.
@discardableResult
func writeComposerProjectFixture(to root: URL, iconPaths: [String], configuredName: String,
                                 resourcePaths: [String]? = nil,
                                 synchronizedDirectory: String? = nil,
                                 excludedPaths: [String] = [],
                                 productType: String = "com.apple.product-type.application") throws -> URL {
    var objects: [String: [String: Any]] = [
        "PROJECT": ["isa": "PBXProject", "mainGroup": "MAIN", "targets": ["APP"]],
        "MAIN": ["isa": "PBXGroup", "sourceTree": "<group>", "children": []],
        "APP": ["isa": "PBXNativeTarget", "productType": productType,
                "buildConfigurationList": "CONFIGS", "buildPhases": ["RESOURCES"]],
        "CONFIGS": ["isa": "XCConfigurationList", "buildConfigurations": ["RELEASE"]],
        "RELEASE": ["isa": "XCBuildConfiguration", "name": "Release",
                    "buildSettings": ["ASSETCATALOG_COMPILER_APPICON_NAME": configuredName]],
        "RESOURCES": ["isa": "PBXResourcesBuildPhase", "files": []]
    ]
    var children: [String] = [], files: [String] = []
    for (index, path) in iconPaths.enumerated() {
        let reference = "REF\(index)", build = "BUILD\(index)"
        objects[reference] = ["isa": "PBXFileReference", "path": path, "sourceTree": "<group>"]
        objects[build] = ["isa": "PBXBuildFile", "fileRef": reference]
        children.append(reference)
        if (resourcePaths ?? iconPaths).contains(path) { files.append(build) }
    }
    if let synchronizedDirectory {
        objects["SYNC"] = ["isa": "PBXFileSystemSynchronizedRootGroup", "path": synchronizedDirectory,
                           "sourceTree": "<group>", "exceptions": ["EXCEPTIONS"]]
        objects["EXCEPTIONS"] = ["isa": "PBXFileSystemSynchronizedBuildFileExceptionSet",
                                 "target": "APP", "membershipExceptions": excludedPaths]
        objects["APP"]?["fileSystemSynchronizedGroups"] = ["SYNC"]
        children.append("SYNC")
    }
    objects["MAIN"]?["children"] = children
    objects["RESOURCES"]?["files"] = files
    let directory = root.appendingPathComponent("Example.xcodeproj")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("project.pbxproj")
    try PropertyListSerialization.data(fromPropertyList: ["rootObject": "PROJECT", "objects": objects], format: .xml, options: 0).write(to: file)
    return file
}

@Test func composerSelectionRequiresExactResourceMembershipAndConfiguredName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let active = root.appendingPathComponent("Resources/AppIcon.icon")
    let stale = root.appendingPathComponent("Old/AppIcon.icon")
    let alternate = root.appendingPathComponent("Resources/Alternate.icon")
    let file = try writeComposerProjectFixture(to: root,
        iconPaths: ["Resources/AppIcon.icon", "Old/AppIcon.icon", "Resources/Alternate.icon"],
        configuredName: "AppIcon", resourcePaths: ["Resources/AppIcon.icon", "Resources/Alternate.icon"])
    #expect(ProjectIconComposerSelection.configuredPackages(in: file, candidates: [stale, alternate, active]) == [active])
}

@Test func composerSelectionDoesNotTreatTestOrFrameworkResourcesAsAppIcons() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeComposerProjectFixture(to: root, iconPaths: ["AppIcon.icon"],
        configuredName: "AppIcon", productType: "com.apple.product-type.bundle.unit-test")
    #expect(ProjectIconComposerSelection.configuredPackages(in: file, candidates: [root.appendingPathComponent("AppIcon.icon")]).isEmpty)
}

@Test func composerSelectionRespectsSynchronizedGroupMembershipExceptions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let active = root.appendingPathComponent("Sources/AppIcon.icon")
    let stale = root.appendingPathComponent("Sources/Archive/AppIcon.icon")
    let outside = root.appendingPathComponent("Old/AppIcon.icon")
    let file = try writeComposerProjectFixture(to: root, iconPaths: [], configuredName: "AppIcon",
        synchronizedDirectory: "Sources", excludedPaths: ["Archive"])
    #expect(ProjectIconComposerSelection.configuredPackages(in: file, candidates: [stale, active, outside]) == [active])
    try writeComposerProjectFixture(to: root, iconPaths: [], configuredName: "AppIcon",
        synchronizedDirectory: "Sources", excludedPaths: ["Archive", "AppIcon.icon"])
    #expect(ProjectIconComposerSelection.configuredPackages(in: file, candidates: [stale, active, outside]).isEmpty)
}

@Test func looseComposerDocumentCannotReplaceActiveCatalog() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("AppIcon.icon")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["groups": [["layers": []]],
        "fill": ["solid": "srgb:1,1,1,1"], "supported-platforms": ["squares": ["macOS"]]])
        .write(to: package.appendingPathComponent("icon.json"))
    let catalog = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let raster = catalog.appendingPathComponent("active.png")
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: raster)
    try Data(#"{"images":[{"filename":"active.png"}]}"#.utf8).write(to: catalog.appendingPathComponent("Contents.json"))
    let withoutProject = await ProjectAppIconLoader.loadPath(for: UUID().uuidString, projectPath: root.path)
    #expect(withoutProject == raster.path)
    // A same-name PBX file reference without resource membership is also stale.
    try writeComposerProjectFixture(to: root, iconPaths: ["AppIcon.icon"], configuredName: "AppIcon", resourcePaths: [])
    let withProject = await ProjectAppIconLoader.loadPath(for: UUID().uuidString, projectPath: root.path)
    #expect(withProject == raster.path)
    // Once the document is configured, a damaged or missing package must not
    // be reported as ready by falling back to that obsolete catalog.
    try writeComposerProjectFixture(to: root, iconPaths: ["AppIcon.icon"], configuredName: "AppIcon")
    try Data("invalid JSON".utf8).write(to: package.appendingPathComponent("icon.json"))
    let brokenID = UUID().uuidString
    #expect(await ProjectAppIconLoader.loadStatus(for: brokenID, projectPath: root.path) == nil)
    #expect(await ProjectAppIconLoader.loadPath(for: brokenID, projectPath: root.path) == nil)
    #expect(await ProjectAppIconLoader.composerPackagePath(for: brokenID, projectPath: root.path) == package.path)
    try FileManager.default.removeItem(at: package)
    let missingID = UUID().uuidString
    #expect(await ProjectAppIconLoader.loadStatus(for: missingID, projectPath: root.path) == nil)
    #expect(await ProjectAppIconLoader.loadPath(for: missingID, projectPath: root.path) == nil)
    #expect(await ProjectAppIconLoader.composerPackagePath(for: missingID, projectPath: root.path) == package.path)
}
