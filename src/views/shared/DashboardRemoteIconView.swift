import AppKit
import ImageIO
import SwiftUI

@MainActor
final class DashboardRemoteIconCache {
    static let shared = DashboardRemoteIconCache()

    final class Entry: NSObject {
        let image: NSImage
        let revision: Int
        init(image: NSImage, revision: Int) { self.image = image; self.revision = revision }
    }

    private let images = NSCache<NSURL, Entry>()

    init() {
        images.countLimit = 128
        images.totalCostLimit = 64 * 1024 * 1024
    }

    func entry(for url: URL) -> Entry? { images.object(forKey: url as NSURL) }

    func store(_ image: NSImage, for url: URL, revision: Int) {
        guard revision >= (entry(for: url)?.revision ?? 0) else { return }
        let cost = image.representations.map { $0.pixelsWide * $0.pixelsHigh * 4 }.max() ?? 0
        images.setObject(Entry(image: image, revision: revision), forKey: url as NSURL, cost: cost)
    }
}

@MainActor
@Observable
final class DashboardRemoteIconLoader {
    private(set) var image: NSImage?
    private(set) var isLoading = false
    private var revision = 0
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    init(fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.fetch = fetch
    }

    func load(url: URL, refreshRevision: Int, cache: DashboardRemoteIconCache) async {
        // A cache hit also supersedes an older in-flight request on this view.
        revision += 1
        isLoading = false
        let saved = cache.entry(for: url)
        if let saved { image = saved.image }
        if let saved, saved.revision >= refreshRevision { return }
        let succeeded = await load(url: url, force: refreshRevision > 0)
        if succeeded, let image { cache.store(image, for: url, revision: refreshRevision) }
    }

    @discardableResult
    func load(url: URL, force: Bool) async -> Bool {
        revision += 1
        let token = revision
        isLoading = true
        defer { if token == revision { isLoading = false } }

        var request = URLRequest(url: url)
        if force {
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        do {
            let (data, response) = try await fetch(request)
            guard token == revision, !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
            // Preserve the decoded pixel dimensions instead of creating a Retina-scaled representation.
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let decoded = NSImage(size: bitmap.size)
            decoded.addRepresentation(bitmap)
            image = decoded
            return true
        } catch {
            // Keep the last successful image through offline, cancelled, and failed refreshes.
            return false
        }
    }
}

struct DashboardRemoteIconView<Placeholder: View>: View {
    let url: URL
    let refreshRevision: Int
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loader = DashboardRemoteIconLoader()

    private struct Request: Hashable {
        let url: URL
        let revision: Int
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if loader.isLoading {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.08))
                    ProgressView().controlSize(.small)
                }
            } else {
                placeholder()
            }
        }
        .task(id: Request(url: url, revision: refreshRevision)) {
            await loader.load(url: url, refreshRevision: refreshRevision, cache: .shared)
        }
    }
}
