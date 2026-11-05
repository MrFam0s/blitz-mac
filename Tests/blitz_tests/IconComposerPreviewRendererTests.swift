import AppKit
import Foundation
import Testing
@testable import Blitz

private func writeComposerPreview(_ url: URL, pixels: Int = 1024) throws {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: url)
}

@Test func composerPreviewCacheSeparatesDocumentPlatformAndRenderer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("App Icon.icon")
    let cache = root.appendingPathComponent("cache")
    var calls = 0
    func render(_ key: String, platform: String = "macOS", rendererVersion: String = "first") -> URL? {
        IconComposerPreviewRenderer.render(packageURL: package, platform: platform, cacheKey: key,
            rendererVersion: rendererVersion, cacheDirectory: cache) { input, output, receivedPlatform in
                #expect(input == package)
                #expect(receivedPlatform == platform)
                #expect(output.deletingLastPathComponent().path == cache.path)
                calls += 1
                do { try writeComposerPreview(output); return true } catch { return false }
            }
    }
    let first = try #require(render("document-a"))
    #expect(render("document-a") == first)
    #expect(calls == 1)
    #expect(render("document-b") != first)
    #expect(render("document-a", platform: "iOS") != first)
    #expect(render("document-a", rendererVersion: "second") != first)
    #expect(calls == 4)
    #expect(!FileManager.default.fileExists(atPath: package.path))
}

@Test func composerPreviewFailedRenderDoesNotPublishPartialImageAndCanRetry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("AppIcon.icon")
    let cache = root.appendingPathComponent("cache")
    let failed = IconComposerPreviewRenderer.render(packageURL: package, platform: "macOS", cacheKey: "key",
        rendererVersion: "test", cacheDirectory: cache) { _, output, _ in
            try? writeComposerPreview(output)
            return false
        }
    #expect(failed == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    let retried = IconComposerPreviewRenderer.render(packageURL: package, platform: "macOS", cacheKey: "key",
        rendererVersion: "test", cacheDirectory: cache) { _, output, _ in
            do { try writeComposerPreview(output); return true } catch { return false }
        }
    #expect(retried != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1)
}

@Test func composerPreviewRejectsBrokenOrUndersizedOutput() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for small in [false, true] {
        let image = IconComposerPreviewRenderer.render(packageURL: root.appendingPathComponent("AppIcon.icon"),
            platform: "macOS", cacheKey: String(small), rendererVersion: "test", cacheDirectory: root) { _, output, _ in
                do {
                    if small { try writeComposerPreview(output, pixels: 32) }
                    else { try Data("partial".utf8).write(to: output) }
                    return true
                } catch { return false }
            }
        #expect(image == nil)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func composerPreviewRejectsUnsupportedPlatformsBeforeLaunch() {
    var called = false
    let value = IconComposerPreviewRenderer.render(packageURL: URL(fileURLWithPath: "/unused/AppIcon.icon"),
        platform: "../macOS", cacheKey: "key", rendererVersion: "test", cacheDirectory: URL(fileURLWithPath: "/unused")) { _, _, _ in
            called = true
            return true
        }
    #expect(value == nil)
    #expect(!called)
}

@Test func composerPreviewProcessTimeoutTerminatesHungTool() {
    let start = Date()
    #expect(!IconComposerPreviewRenderer.runProcess(executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["5"], timeout: 0.05))
    #expect(Date().timeIntervalSince(start) < 2)
    #expect(IconComposerPreviewRenderer.runProcess(executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [], timeout: 2))
    #expect(!IconComposerPreviewRenderer.runProcess(executableURL: URL(fileURLWithPath: "/does-not-exist/ictool"),
        arguments: [], timeout: 2))
}

@Test func composerPreviewDoesNotCacheSourceChangedDuringRendering() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source-content")
    let original = Data("original document".utf8)
    try original.write(to: source)
    let cache = root.appendingPathComponent("cache")
    let result = IconComposerPreviewRenderer.render(packageURL: root.appendingPathComponent("AppIcon.icon"),
        platform: "macOS", cacheKey: "original-key", rendererVersion: "test", cacheDirectory: cache,
        isSourceCurrent: { (try? Data(contentsOf: source)) == original }) { _, output, _ in
            do {
                try Data("changed document".utf8).write(to: source)
                try writeComposerPreview(output)
                return true
            } catch { return false }
        }
    #expect(result == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
}

@Test func composerPreviewDoesNotReuseCacheForOutdatedSource() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("AppIcon.icon")
    let cached = IconComposerPreviewRenderer.render(packageURL: package, platform: "macOS", cacheKey: "key",
        rendererVersion: "test", cacheDirectory: root) { _, output, _ in
            do { try writeComposerPreview(output); return true } catch { return false }
        }
    #expect(cached != nil)
    var rendered = false
    let outdated = IconComposerPreviewRenderer.render(packageURL: package, platform: "macOS", cacheKey: "key",
        rendererVersion: "test", cacheDirectory: root, isSourceCurrent: { false }) { _, _, _ in
            rendered = true
            return true
        }
    #expect(outdated == nil)
    #expect(!rendered)
}
