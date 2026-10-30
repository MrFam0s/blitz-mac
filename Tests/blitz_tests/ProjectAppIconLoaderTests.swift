import AppKit
import Foundation
import Testing
@testable import Blitz

@Test func testProjectAppIconLoaderResolvesSymlinkedProjectPaths() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("project-app-icon-loader-\(UUID().uuidString)", isDirectory: true)
    let realProject = root.appendingPathComponent("real-project", isDirectory: true)
    let symlinkProject = root.appendingPathComponent("linked-project", isDirectory: false)

    try fileManager.createDirectory(at: realProject, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    try writeTestAppIcon(to: realProject)
    try fileManager.createSymbolicLink(at: symlinkProject, withDestinationURL: realProject)

    let image = await ProjectAppIconLoader.loadImage(
        for: "symlinked-project-\(UUID().uuidString)",
        projectPath: symlinkProject.path
    )

    #expect(image != nil)
}

@Test func testProjectAppIconLoaderRetriesAfterMissingCache() async throws {
    let fileManager = FileManager.default
    let projectRoot = fileManager.temporaryDirectory
        .appendingPathComponent("project-app-icon-retry-\(UUID().uuidString)", isDirectory: true)
    let projectId = "retry-project-\(UUID().uuidString)"

    try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: projectRoot) }

    let missingImage = await ProjectAppIconLoader.loadImage(
        for: projectId,
        projectPath: projectRoot.path
    )
    #expect(missingImage == nil)

    try writeTestAppIcon(to: projectRoot)

    let image = await ProjectAppIconLoader.loadImage(
        for: projectId,
        projectPath: projectRoot.path
    )

    #expect(image != nil)
}

private func writeTestAppIcon(to projectRoot: URL) throws {
    let fileManager = FileManager.default
    let appIconSet = projectRoot
        .appendingPathComponent("Example", isDirectory: true)
        .appendingPathComponent("Assets.xcassets", isDirectory: true)
        .appendingPathComponent("AppIcon.appiconset", isDirectory: true)

    try fileManager.createDirectory(at: appIconSet, withIntermediateDirectories: true)

    let contents = """
    {
      "images" : [
        {
          "filename" : "AppIcon.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """

    try contents.write(
        to: appIconSet.appendingPathComponent("Contents.json"),
        atomically: true,
        encoding: .utf8
    )

    guard let image = NSImage(
        systemSymbolName: "app.fill",
        accessibilityDescription: nil
    ) else {
        Issue.record("Failed to create test icon image")
        return
    }

    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1024,
        pixelsHigh: 1024,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )

    guard let bitmap else {
        Issue.record("Failed to allocate bitmap for test icon")
        return
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
    image.draw(in: NSRect(x: 128, y: 128, width: 768, height: 768))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        Issue.record("Failed to encode test icon PNG")
        return
    }

    try data.write(to: appIconSet.appendingPathComponent("AppIcon.png"))
}

@Test func projectIconStatusIgnoresGeneratedBuildTrees() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try writeTestAppIcon(to: root.appendingPathComponent(".build"))
    let projectId = UUID().uuidString
    #expect(await ProjectAppIconLoader.loadStatus(for: projectId, projectPath: root.path) == nil)
    try writeTestAppIcon(to: root)
    #expect(await ProjectAppIconLoader.loadStatus(for: projectId, projectPath: root.path) == "Configured")
}

@Test func projectIconChoosesActualPixelsInsteadOfAssetOrderOrPointSize() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let set = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try writePixelIcon(to: set.appendingPathComponent("small.png"), pixels: 32)
    try writePixelIcon(to: set.appendingPathComponent("large.png"), pixels: 1024)
    try writeIconContents(to: set, images: [
        ["filename": "small.png", "size": "1024x1024"],
        ["filename": "large.png", "size": "512x512", "scale": "2x"]
    ])
    let id = UUID().uuidString
    let path = await ProjectAppIconLoader.loadPath(for: id, projectPath: root.path)
    #expect(path == set.appendingPathComponent("large.png").path)
    let image = await ProjectAppIconLoader.loadImage(for: id, projectPath: root.path)
    #expect(image?.representations.map(\.pixelsWide).max() == 1024)
}

@Test func projectIconSkipsBrokenFilesAndPrefersDefaultAppearanceAtEqualSize() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let set = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try Data("not an image".utf8).write(to: set.appendingPathComponent("broken.png"))
    try writePixelIcon(to: set.appendingPathComponent("dark.png"), pixels: 1024)
    try writePixelIcon(to: set.appendingPathComponent("regular.png"), pixels: 1024)
    try writeIconContents(to: set, images: [
        ["filename": "missing.png"], ["filename": "broken.png"],
        ["filename": "dark.png", "appearances": [["appearance": "luminosity", "value": "dark"]]],
        ["filename": "regular.png"]
    ])
    let path = await ProjectAppIconLoader.loadPath(for: UUID().uuidString, projectPath: root.path)
    #expect(path == set.appendingPathComponent("regular.png").path)
}

@Test func projectIconPrefersCatalogOverStaleGeneratedCopies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try writeTestAppIcon(to: root)
    let generated = root.appendingPathComponent("assets/AppIcon/icon_1024.png")
    try FileManager.default.createDirectory(at: generated.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writePixelIcon(to: generated, pixels: 32)
    let id = UUID().uuidString
    #expect(await ProjectAppIconLoader.loadPath(for: id, projectPath: root.path)?.hasSuffix("AppIcon.png") == true)
    for pixels in [1024, 2048] {
        try writePixelIcon(to: generated, pixels: pixels)
        _ = await ProjectAppIconLoader.refreshImage(for: id, projectPath: root.path)
        #expect(await ProjectAppIconLoader.loadPath(for: id, projectPath: root.path)?.hasSuffix("AppIcon.png") == true)
    }
}

@Test func projectIconFallsBackToGeneratedCopyOnlyWithoutUsableCatalog() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let generated = root.appendingPathComponent("assets/AppIcon/icon_1024.png")
    try FileManager.default.createDirectory(at: generated.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writePixelIcon(to: generated, pixels: 1024)
    let id = UUID().uuidString
    #expect(await ProjectAppIconLoader.loadPath(for: id, projectPath: root.path) == generated.path)

    let set = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try writeIconContents(to: set, images: [["filename": "active.png"]])
    try Data("broken image".utf8).write(to: set.appendingPathComponent("active.png"))
    _ = await ProjectAppIconLoader.refreshImage(for: id, projectPath: root.path)
    #expect(await ProjectAppIconLoader.loadPath(for: id, projectPath: root.path) == generated.path)

    try writePixelIcon(to: set.appendingPathComponent("active.png"), pixels: 512)
    _ = await ProjectAppIconLoader.refreshImage(for: id, projectPath: root.path)
    #expect(await ProjectAppIconLoader.loadPath(for: id, projectPath: root.path) == set.appendingPathComponent("active.png").path)
}

private func writePixelIcon(to url: URL, pixels: Int) throws {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: url)
}

private func writeIconContents(to set: URL, images: [[String: Any]]) throws {
    try JSONSerialization.data(withJSONObject: ["images": images])
        .write(to: set.appendingPathComponent("Contents.json"))
}

@MainActor
@Test func dashboardForceRefreshReloadsChangedLocalIconEvenWhenASCIsOffline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let set = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    let file = set.appendingPathComponent("icon.png")
    try writePixelIcon(to: file, pixels: 32)
    try writeIconContents(to: set, images: [["filename": "icon.png"]])
    let project = Project(id: UUID().uuidString,
                          metadata: BlitzProjectMetadata(name: "Example", type: .swift), path: root.path)
    let old = try #require(await ProjectAppIconLoader.loadImage(for: project.id, projectPath: project.path))
    #expect(old.representations.map(\.pixelsWide).max() == 32)
    try writePixelIcon(to: file, pixels: 128)

    let store = DashboardSummaryStore(cacheURL: root.appendingPathComponent("cache.json"), accountKeyOverride: "test")
    await store.refresh(for: "test", accountKey: "test", service: OfflineIconDashboardFetcher(),
                        projects: [project], force: true)

    #expect(store.loadIssue == .offline)
    #expect(store.iconRefreshRevision == 1)
    let refreshed = try #require(await ProjectAppIconLoader.loadImage(for: project.id, projectPath: project.path))
    #expect(refreshed.representations.map(\.pixelsWide).max() == 128)

    // The next refresh must also discard the cached path and discover the best new asset.
    try writePixelIcon(to: set.appendingPathComponent("large.png"), pixels: 1024)
    try writeIconContents(to: set, images: [["filename": "icon.png"], ["filename": "large.png"]])
    store.refreshIcons(for: [project])
    #expect(await ProjectAppIconLoader.loadPath(for: project.id, projectPath: project.path) == set.appendingPathComponent("large.png").path)
    // Dashboard and sidebar subscribers share one invalidation and load concurrently.
    async let first = ProjectAppIconLoader.loadImage(for: project.id, projectPath: project.path)
    async let second = ProjectAppIconLoader.loadImage(for: project.id, projectPath: project.path)
    let (dashboard, sidebar) = await (first, second)
    #expect(dashboard?.representations.map(\.pixelsWide).max() == 1024)
    #expect(sidebar?.representations.map(\.pixelsWide).max() == 1024)
}

private struct OfflineIconDashboardFetcher: DashboardFetching {
    func fetchAllApps(appStoreStateFilter: String?) async throws -> [ASCApp] {
        throw URLError(.notConnectedToInternet)
    }
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] { [] }
    func fetchAppStoreIconURL(app: ASCApp, dimension: Int) async throws -> URL? { nil }
}
