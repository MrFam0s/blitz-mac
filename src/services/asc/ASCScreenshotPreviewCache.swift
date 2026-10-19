import CryptoKit
import Foundation
import ImageIO

/// Account/app-scoped CDN previews, not original upload files or tester images.
actor ASCScreenshotPreviewCache {
    static let shared = ASCScreenshotPreviewCache()
    static let maximumAge: TimeInterval = 7 * 86400
    static let maximumImageBytes = 8 * 1024 * 1024
    private let directory: URL
    private let maximumBytes: Int
    private let maximumEntries: Int
    private let download: (URL) async throws -> Data
    private var pending: [String: Task<Data?, Never>] = [:]

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
         .appendingPathComponent("com.blitz.macos/asc-previews", isDirectory: true),
         maximumBytes: Int = 128 * 1024 * 1024, maximumEntries: Int = 300,
         download: @escaping (URL) async throws -> Data = ASCScreenshotPreviewCache.fetch) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumEntries = maximumEntries
        self.download = download
    }

    func data(scope: String, url: URL, force: Bool = false, now: Date = Date()) async -> Data? {
        let key = SHA256.hash(data: Data("\(scope)\u{0}\(url.absoluteString)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        if let task = pending[key] { return await task.value }
        let file = directory.appendingPathComponent(key + ".image")
        if !force, let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
           let date = values.contentModificationDate, let size = values.fileSize,
           size <= Self.maximumImageBytes, (-60...Self.maximumAge).contains(now.timeIntervalSince(date)),
           let bytes = try? Data(contentsOf: file), Self.valid(bytes) { return bytes }
        let task = Task { [self] () -> Data? in
            guard let bytes = try? await download(url), Self.valid(bytes) else { return nil }
            save(bytes, at: file)
            return bytes
        }
        pending[key] = task
        let result = await task.value
        pending.removeValue(forKey: key)
        return result
    }

    private static func valid(_ bytes: Data) -> Bool {
        !bytes.isEmpty && bytes.count <= maximumImageBytes
            && CGImageSourceCreateWithData(bytes as CFData, nil).map { CGImageSourceGetCount($0) > 0 } == true
    }

    nonisolated private static func fetch(_ url: URL) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return bytes
    }

    private func save(_ bytes: Data, at file: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
                .filter { $0.pathExtension == "image" }
                .compactMap { file -> (URL, Int, Date)? in
                    guard let info = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                    return (file, info.fileSize ?? 0, info.contentModificationDate ?? .distantPast)
                }.sorted { $0.2 > $1.2 }
            var used = 0
            for (index, item) in files.enumerated() {
                used += item.1
                if used > maximumBytes || index >= maximumEntries || Date().timeIntervalSince(item.2) > Self.maximumAge {
                    try? fm.removeItem(at: item.0)
                }
            }
        } catch { /* Downloads remain usable when disk caching is unavailable. */ }
    }
}
