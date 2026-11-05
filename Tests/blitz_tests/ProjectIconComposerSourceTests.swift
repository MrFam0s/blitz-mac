import AppKit
import Foundation
import Testing
@testable import Blitz

private func composerFixture(_ root: URL, name: String = "AppIcon", imageName: String = "glyph.png") throws -> URL {
    let package = root.appendingPathComponent(name + ".icon")
    try FileManager.default.createDirectory(at: package.appendingPathComponent("Assets"), withIntermediateDirectories: true)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: package.appendingPathComponent("Assets/glyph.png"))
    let document: [String: Any] = [
        "groups": [["layers": [["image-name": imageName]]]],
        "fill-specializations": [["value": ["solid": "srgb:1,1,1,1"]]],
        "supported-platforms": ["squares": ["macOS"]]
    ]
    try JSONSerialization.data(withJSONObject: document).write(to: package.appendingPathComponent("icon.json"))
    return package
}

@Test func composerIsConfiguredWithoutPreviewRendererAndNeverShowsLayerOrStalePNG() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = try composerFixture(root)
    let set = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: package.appendingPathComponent("Assets/glyph.png"), to: set.appendingPathComponent("old.png"))
    try Data(#"{"images":[{"filename":"old.png"}]}"#.utf8).write(to: set.appendingPathComponent("Contents.json"))
    try writeComposerProjectFixture(to: root, iconPaths: ["AppIcon.icon"], configuredName: "AppIcon")
    let id = UUID().uuidString
    #expect(await ProjectAppIconLoader.loadStatus(for: id, projectPath: root.path) == "Configured")
    #expect(await ProjectAppIconLoader.composerPackagePath(for: id, projectPath: root.path) == package.path)
    #expect(await ProjectAppIconLoader.loadPath(for: id, projectPath: root.path, renderComposer: { _, _, _ in nil }) == nil)
    #expect(await ProjectAppIconLoader.loadStatus(for: id, projectPath: root.path) == "Configured")
    let preview = root.appendingPathComponent("rendered-preview.png")
    let path = await ProjectAppIconLoader.loadPath(for: id, projectPath: root.path) { input, platform, key in
        #expect(input.path == package.path)
        #expect(platform == "macOS")
        #expect(!key.isEmpty)
        return preview
    }
    #expect(path == preview.path)
}

@Test func composerSourceResolvesSymlinkedProjectAndUniqueCustomName() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real")
    let package = try composerFixture(real, name: "CustomIcon")
    let linked = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
    #expect(await ProjectAppIconLoader.composerPackagePath(for: UUID().uuidString, projectPath: linked.path) == package.path)
}

@Test func composerSelectionUsesConfiguredNameAndRejectsAmbiguousTargets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try composerFixture(root, name: "First")
    let selected = try composerFixture(root, name: "Second")
    #expect(await ProjectAppIconLoader.loadStatus(for: UUID().uuidString, projectPath: root.path) == nil)
    try writeComposerProjectFixture(to: root, iconPaths: ["First.icon", "Second.icon"], configuredName: "Second")
    #expect(await ProjectAppIconLoader.composerPackagePath(for: UUID().uuidString, projectPath: root.path) == selected.path)
}

@Test func composerRefreshUsesChangedDocumentAndLayerContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = try composerFixture(root)
    let first = try #require(ProjectIconComposerSource(packageURL: package, projectRoot: root))
    let id = UUID().uuidString
    let old = await ProjectAppIconLoader.loadPath(for: id, projectPath: root.path) { _, _, key in root.appendingPathComponent(key) }
    let document = package.appendingPathComponent("icon.json")
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: document)) as? [String: Any])
    json["fill"] = ["solid": "srgb:0,0,0,1"]
    try JSONSerialization.data(withJSONObject: json).write(to: document)
    let second = try #require(ProjectIconComposerSource(packageURL: package, projectRoot: root))
    #expect(first.cacheKey != second.cacheKey)
    let glyph = package.appendingPathComponent("Assets/glyph.png")
    var data = try Data(contentsOf: glyph)
    data.append(contentsOf: [0, 0])
    try data.write(to: glyph)
    let third = try #require(ProjectIconComposerSource(packageURL: package, projectRoot: root))
    #expect(second.cacheKey != third.cacheKey)
    ProjectAppIconLoader.invalidate(for: id)
    let refreshed = await ProjectAppIconLoader.loadPath(for: id, projectPath: root.path) { _, _, key in root.appendingPathComponent(key) }
    #expect(old != refreshed)
    #expect(refreshed == root.appendingPathComponent(third.cacheKey).path)
}

@Test func composerRejectsMissingAssetsBrokenJSONAndEscapingPaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = try composerFixture(root, imageName: "../outside.png")
    try FileManager.default.copyItem(at: package.appendingPathComponent("Assets/glyph.png"), to: package.appendingPathComponent("outside.png"))
    #expect(ProjectIconComposerSource(packageURL: package, projectRoot: root) == nil)
    _ = try composerFixture(root, imageName: "missing.png")
    #expect(ProjectIconComposerSource(packageURL: package, projectRoot: root) == nil)
    try Data("invalid json".utf8).write(to: package.appendingPathComponent("icon.json"))
    #expect(ProjectIconComposerSource(packageURL: package, projectRoot: root) == nil)
    _ = try composerFixture(root)
    try FileManager.default.removeItem(at: package.appendingPathComponent("Assets/glyph.png"))
    try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("Assets/glyph.png"), withDestinationURL: package.appendingPathComponent("outside.png"))
    #expect(ProjectIconComposerSource(packageURL: package, projectRoot: root) == nil)
}

@Test func composerDiscoveryIgnoresBuildCopiesAndPackagesOutsideProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    _ = try composerFixture(project.appendingPathComponent("build"))
    let external = try composerFixture(root.appendingPathComponent("outside"))
    try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("AppIcon.icon"), withDestinationURL: external)
    #expect(await ProjectAppIconLoader.loadStatus(for: UUID().uuidString, projectPath: project.path) == nil)
}

@Test func composerRenderCannotReturnOldPreviewAfterDashboardInvalidation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try composerFixture(root)
    let id = UUID().uuidString
    let stale = await ProjectAppIconLoader.loadPath(for: id, projectPath: root.path) { _, _, _ in
        ProjectAppIconLoader.invalidate(for: id)
        return root.appendingPathComponent("stale.png")
    }
    #expect(stale == nil)
}

@Test func composerRejectsCorruptLayerAndInvalidPlatformButAcceptsSVG() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = try composerFixture(root)
    try Data("not a PNG".utf8).write(to: package.appendingPathComponent("Assets/glyph.png"))
    #expect(ProjectIconComposerSource(packageURL: package, projectRoot: root) == nil)
    _ = try composerFixture(root, imageName: "glyph.svg")
    try Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><path d="M0 0 L10 10"/></svg>"#.utf8)
        .write(to: package.appendingPathComponent("Assets/glyph.svg"))
    #expect(ProjectIconComposerSource(packageURL: package, projectRoot: root) != nil)
    let document = package.appendingPathComponent("icon.json")
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: document)) as? [String: Any])
    json["supported-platforms"] = [:] as [String: Any]
    try JSONSerialization.data(withJSONObject: json).write(to: document)
    #expect(ProjectIconComposerSource(packageURL: package, projectRoot: root) == nil)
}
