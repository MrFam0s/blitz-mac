import AppKit
import Foundation
import Testing
@testable import Blitz

@Test func iconCatalogImportUpdatesEveryDefaultSizeAndPreservesAppearances() throws {
    let root = iconWriterTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let set = root.appendingPathComponent("Example/Assets.xcassets/AppIcon.appiconset")
    try writeCatalogFixture(to: set, images: [
        ["filename": "16.png", "size": "16x16", "scale": "1x"],
        ["filename": "32.png", "size": "16x16", "scale": "2x"],
        ["filename": "32.png", "size": "32x32", "scale": "1x"],
        ["filename": "167.png", "size": "83.5x83.5", "scale": "2x"],
        ["filename": "1024.png", "size": "512x512", "scale": "2x"],
        ["filename": "dark.png", "size": "1024x1024",
         "appearances": [["appearance": "luminosity", "value": "dark"]]],
        ["filename": "tinted.png", "size": "1024x1024",
         "appearances": [["appearance": "luminosity", "value": "tinted"]]]
    ])
    let old = try iconWriterPNG(pixels: 32)
    for filename in ["16.png", "32.png", "1024.png", "dark.png", "tinted.png"] {
        try old.write(to: set.appendingPathComponent(filename))
    }
    let metadata = try Data(contentsOf: set.appendingPathComponent("Contents.json"))
    try ProjectAppIconCatalogWriter.write(source: iconWriterSource(), projectPath: root.path)

    for pixels in [16, 32, 167, 1024] {
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: set.appendingPathComponent("\(pixels).png"))))
        #expect(image.pixelsWide == pixels)
        #expect(image.pixelsHigh == pixels)
        let color = try #require(image.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(color.redComponent > 0.99)
        #expect(color.blueComponent < 0.01)
    }
    #expect(try Data(contentsOf: set.appendingPathComponent("dark.png")) == old)
    #expect(try Data(contentsOf: set.appendingPathComponent("tinted.png")) == old)
    #expect(try Data(contentsOf: set.appendingPathComponent("Contents.json")) == metadata)
}

@Test func iconCatalogImportHandlesLegacyUniversalEntriesAndSymlinkedProjects() throws {
    let root = iconWriterTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("real")
    let set = project.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try writeCatalogFixture(to: set, images: [
        ["filename": "legacy.png", "idiom": "universal"],
        ["filename": "new.png", "idiom": "universal"]
    ])
    try iconWriterPNG(pixels: 128).write(to: set.appendingPathComponent("legacy.png"))
    let linked = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: project)
    try ProjectAppIconCatalogWriter.write(source: iconWriterSource(), projectPath: linked.path)
    let legacy = try #require(NSBitmapImageRep(data: Data(contentsOf: set.appendingPathComponent("legacy.png"))))
    let new = try #require(NSBitmapImageRep(data: Data(contentsOf: set.appendingPathComponent("new.png"))))
    #expect(legacy.pixelsWide == 128)
    #expect(new.pixelsWide == 1024)
}

@Test func iconCatalogImportSkipsBuildAndDependencyCopies() throws {
    let root = iconWriterTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let images: [[String: Any]] = [["filename": "icon.png", "size": "32x32"]]
    let old = try iconWriterPNG(pixels: 32)
    let skipped = [".build", "DerivedData", "build", "node_modules", "Pods", "vendor", "deps", "ThirdParty", "target"]
    for directory in skipped + ["ZProject"] {
        let set = root.appendingPathComponent("\(directory)/Assets.xcassets/AppIcon.appiconset")
        try writeCatalogFixture(to: set, images: images)
        try old.write(to: set.appendingPathComponent("icon.png"))
    }
    try ProjectAppIconCatalogWriter.write(source: iconWriterSource(), projectPath: root.path)
    for directory in skipped {
        #expect(try Data(contentsOf: root.appendingPathComponent("\(directory)/Assets.xcassets/AppIcon.appiconset/icon.png")) == old)
    }
    #expect(try Data(contentsOf: root.appendingPathComponent("ZProject/Assets.xcassets/AppIcon.appiconset/icon.png")) != old)
}

@Test(arguments: ["../outside.png", "linked.png"])
func iconCatalogImportRejectsEscapingFilenamesBeforeWriting(filename: String) throws {
    let root = iconWriterTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let set = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try writeCatalogFixture(to: set, images: [
        ["filename": "safe.png", "size": "32x32"],
        ["filename": filename, "size": "32x32"]
    ])
    let old = try iconWriterPNG(pixels: 32)
    let outside = set.deletingLastPathComponent().appendingPathComponent("outside.png")
    try old.write(to: outside)
    try old.write(to: set.appendingPathComponent("safe.png"))
    try FileManager.default.createSymbolicLink(at: set.appendingPathComponent("linked.png"), withDestinationURL: outside)
    #expect(throws: (any Error).self) {
        try ProjectAppIconCatalogWriter.write(source: iconWriterSource(), projectPath: root.path)
    }
    #expect(try Data(contentsOf: outside) == old)
    #expect(try Data(contentsOf: set.appendingPathComponent("safe.png")) == old)
}

@Test func iconCatalogImportPropagatesFileWriteFailures() throws {
    let root = iconWriterTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let set = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try writeCatalogFixture(to: set, images: [["filename": "icon.png", "size": "32x32"]])
    // A directory at the image destination reliably fails even under a privileged test runner.
    try FileManager.default.createDirectory(at: set.appendingPathComponent("icon.png"), withIntermediateDirectories: true)
    #expect(throws: (any Error).self) {
        try ProjectAppIconCatalogWriter.write(source: iconWriterSource(), projectPath: root.path)
    }
}

@Test func iconCatalogImportWithoutCatalogLeavesGeneratedFallbackUntouched() throws {
    let root = iconWriterTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let generated = root.appendingPathComponent("assets/AppIcon/icon_1024.png")
    try FileManager.default.createDirectory(at: generated.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = try iconWriterPNG(pixels: 32)
    try old.write(to: generated)
    try ProjectAppIconCatalogWriter.write(source: iconWriterSource(), projectPath: root.path)
    #expect(try Data(contentsOf: generated) == old)
}

@Test func iconCatalogImportReportsConflictingAppearanceFilenames() throws {
    let root = iconWriterTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let set = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try writeCatalogFixture(to: set, images: [
        ["filename": "shared.png", "size": "32x32"],
        ["filename": "shared.png", "size": "32x32",
         "appearances": [["appearance": "luminosity", "value": "dark"]]]
    ])
    let old = try iconWriterPNG(pixels: 32)
    try old.write(to: set.appendingPathComponent("shared.png"))
    #expect(throws: (any Error).self) {
        try ProjectAppIconCatalogWriter.write(source: iconWriterSource(), projectPath: root.path)
    }
    #expect(try Data(contentsOf: set.appendingPathComponent("shared.png")) == old)
}

private func iconWriterTestRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("icon-catalog-writer-\(UUID().uuidString)")
}

private func writeCatalogFixture(to set: URL, images: [[String: Any]]) throws {
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["images": images])
        .write(to: set.appendingPathComponent("Contents.json"))
}

private func iconWriterSource(pixels: Int = 1024, red: CGFloat = 1) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: red, green: 0, blue: 1 - red, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return try #require(context.makeImage())
}

private func iconWriterPNG(pixels: Int) throws -> Data {
    try #require(NSBitmapImageRep(cgImage: iconWriterSource(pixels: pixels, red: 0)).representation(using: .png, properties: [:]))
}
