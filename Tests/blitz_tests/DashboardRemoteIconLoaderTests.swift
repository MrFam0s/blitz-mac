import AppKit
import Foundation
import Testing
@testable import Blitz

@MainActor
@Test func dashboardRemoteIconRefreshReloadsTheSameURLAndRetainsImageOnFailure() async throws {
    let url = try #require(URL(string: "https://example.invalid/icon.png"))
    let small = try remoteIconPNG(pixels: 32)
    let large = try remoteIconPNG(pixels: 1024)
    var requests: [URLRequest] = []
    let loader = DashboardRemoteIconLoader { request in
        requests.append(request)
        switch requests.count {
        case 1: return (small, iconResponse(url: url, status: 200))
        case 2: return (large, iconResponse(url: url, status: 200))
        case 3: throw URLError(.notConnectedToInternet)
        case 4: return (Data("invalid image".utf8), iconResponse(url: url, status: 200))
        default: return (small, iconResponse(url: url, status: 503))
        }
    }
    await loader.load(url: url, force: false)
    #expect(loader.image?.representations.map(\.pixelsWide).max() == 32)
    await loader.load(url: url, force: true)
    let fresh = try #require(loader.image)
    #expect(fresh.representations.map(\.pixelsWide).max() == 1024)
    #expect(requests.map(\.url) == [url, url])
    #expect(requests[0].cachePolicy == .useProtocolCachePolicy)
    #expect(requests[1].cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(requests[1].value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    for _ in 0..<3 {
        await loader.load(url: url, force: true)
        #expect(loader.image === fresh)
        #expect(!loader.isLoading)
    }
}

@MainActor
@Test func dashboardRemoteIconIgnoresLatePreRefreshResponses() async throws {
    let url = try #require(URL(string: "https://example.invalid/icon.png"))
    let small = try remoteIconPNG(pixels: 32)
    let large = try remoteIconPNG(pixels: 1024)
    let delayed = DelayedIconDownload()
    // Capture the old response before allowing the replacement request to complete.
    let oldLoader = DashboardRemoteIconLoader { request in
        if request.cachePolicy == .useProtocolCachePolicy {
            await delayed.wait()
            return (small, iconResponse(url: url, status: 200))
        }
        return (large, iconResponse(url: url, status: 200))
    }
    let pending = Task { await oldLoader.load(url: url, force: false) }
    await delayed.waitForRequest()
    await oldLoader.load(url: url, force: true)
    #expect(oldLoader.image?.representations.map(\.pixelsWide).max() == 1024)
    delayed.finish()
    await pending.value
    #expect(oldLoader.image?.representations.map(\.pixelsWide).max() == 1024)
    #expect(!oldLoader.isLoading)
}

@MainActor
private final class DelayedIconDownload {
    private var continuation: CheckedContinuation<Void, Never>?
    private var requested: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            requested?.resume()
            requested = nil
        }
    }
    func waitForRequest() async {
        if continuation == nil { await withCheckedContinuation { requested = $0 } }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

private func remoteIconPNG(pixels: Int) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

private func iconResponse(url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

@MainActor
@Test func dashboardRemoteIconRemountReusesRefreshedImageAndRetriesFailedRefresh() async throws {
    let cache = DashboardRemoteIconCache()
    let url = try #require(URL(string: "https://example.invalid/icon.png"))
    let png = try remoteIconPNG(pixels: 1024)
    var requests = 0
    let first = DashboardRemoteIconLoader { _ in
        requests += 1
        return (png, iconResponse(url: url, status: 200))
    }
    await first.load(url: url, refreshRevision: 1, cache: cache)
    #expect(requests == 1)
    let original = try #require(first.image)
    let remounted = DashboardRemoteIconLoader { _ in
        requests += 1
        throw URLError(.notConnectedToInternet)
    }
    await remounted.load(url: url, refreshRevision: 1, cache: cache)
    #expect(requests == 1)
    #expect(remounted.image === original)
    await remounted.load(url: url, refreshRevision: 2, cache: cache)
    #expect(requests == 2)
    #expect(remounted.image === original)
    #expect(cache.entry(for: url)?.revision == 1)
    await first.load(url: url, refreshRevision: 2, cache: cache)
    #expect(requests == 3)
    #expect(cache.entry(for: url)?.revision == 2)
}

@MainActor
@Test func dashboardRemoteIconCacheHitSupersedesAnInFlightRequest() async throws {
    let cache = DashboardRemoteIconCache()
    let oldURL = try #require(URL(string: "https://example.invalid/old.png"))
    let currentURL = try #require(URL(string: "https://example.invalid/current.png"))
    let oldPNG = try remoteIconPNG(pixels: 32)
    let current = try #require(NSImage(data: remoteIconPNG(pixels: 1024)))
    cache.store(current, for: currentURL, revision: 1)
    let delayed = DelayedIconDownload()
    let loader = DashboardRemoteIconLoader { _ in
        await delayed.wait()
        return (oldPNG, iconResponse(url: oldURL, status: 200))
    }
    let pending = Task { await loader.load(url: oldURL, refreshRevision: 1, cache: cache) }
    await delayed.waitForRequest()
    await loader.load(url: currentURL, refreshRevision: 1, cache: cache)
    #expect(loader.image === current)
    #expect(!loader.isLoading)
    delayed.finish()
    await pending.value
    #expect(loader.image === current)
    #expect(cache.entry(for: oldURL) == nil)
}
