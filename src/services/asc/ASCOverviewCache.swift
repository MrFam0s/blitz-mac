import CryptoKit
import Foundation

/// Only listing metadata is persisted. Review contacts, demo credentials, login
/// material, draft edits, image bytes and tester data deliberately stay out.
struct ASCOverviewCacheEntry: Codable {
    let schema: Int
    let savedAt: Date
    let app: ASCApp
    let versions: [ASCAppStoreVersion]
    let selectedVersionId: String?
    let localizations: [ASCVersionLocalization]
    let appInfo: ASCAppInfo?
    let appInfoLocalizations: [String: ASCAppInfoLocalization]
    let ageRating: ASCAgeRatingDeclaration?
    let screenshotSets: [String: [ASCScreenshotSet]]
    let screenshots: [String: [String: [ASCScreenshot]]]
    let selectedBuild: ASCBuild?
    let resolvedFields: Set<String>

    @MainActor
    init(manager: ASCManager, savedAt: Date = Date()) {
        schema = 1
        self.savedAt = savedAt
        app = manager.app!
        versions = manager.appStoreVersions
        selectedVersionId = manager.selectedVersionId
        localizations = manager.localizations
        appInfo = manager.appInfo
        appInfoLocalizations = manager.appInfoLocalizationsByLocale
        ageRating = manager.ageRatingDeclaration
        screenshotSets = manager.screenshotSetsByLocale
        screenshots = manager.screenshotsByLocale
        selectedBuild = manager.selectedVersionBuild
        resolvedFields = manager.overviewResolvedFields
            .subtracting(ASCManager.overviewReviewFieldLabels)
            .subtracting(ASCManager.overviewPricingFieldLabels)
            .subtracting(["App Icon"])
    }

    @MainActor
    func apply(to manager: ASCManager) {
        manager.app = app
        manager.appStoreVersions = versions
        manager.selectedVersionId = selectedVersionId
        manager.localizations = localizations
        manager.appInfo = appInfo
        manager.appInfoLocalizationsByLocale = appInfoLocalizations
        manager.appInfoLocalization = manager.primaryAppInfoLocalization(in: Array(appInfoLocalizations.values))
        manager.ageRatingDeclaration = ageRating
        manager.screenshotSetsByLocale = screenshotSets
        manager.screenshotsByLocale = screenshots
        manager.selectedVersionBuild = selectedBuild
        manager.overviewResolvedFields = resolvedFields
        manager.overviewReadinessLoadingFields = ASCManager.overviewAllFields.subtracting(resolvedFields)
        manager.overviewCacheDate = savedAt
        manager.loadedTabs.insert(.app)
        // A disk restore always revalidates, including uncached private fields.
        manager.tabLoadedAt[.app] = .distantPast
    }
}

actor ASCOverviewCache {
    static let shared = ASCOverviewCache()
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    static let maximumEntries = 24
    static let maximumEntryBytes = 2 * 1024 * 1024
    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.blitz.macos/asc-overviews", isDirectory: true)) {
        self.directory = directory
    }

    private func url(account: String, bundle: String) -> URL {
        let digest = SHA256.hash(data: Data("\(account)\u{0}\(bundle)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    func load(account: String, bundle: String, now: Date = Date()) -> ASCOverviewCacheEntry? {
        let file = url(account: account, bundle: bundle)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumEntryBytes,
              let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(ASCOverviewCacheEntry.self, from: data),
              entry.schema == 1, entry.app.bundleId == bundle,
              now.timeIntervalSince(entry.savedAt) >= -60,
              now.timeIntervalSince(entry.savedAt) <= Self.maximumAge else { return nil }
        return entry
    }

    func save(_ entry: ASCOverviewCacheEntry, account: String) {
        let fm = FileManager.default
        guard let data = try? JSONEncoder().encode(entry), data.count <= Self.maximumEntryBytes else { return }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let file = url(account: account, bundle: entry.app.bundleId)
            try data.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let files = try fm.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" }
                .sorted { modified($0) > modified($1) }
            for (index, old) in files.enumerated()
                where index >= Self.maximumEntries || Date().timeIntervalSince(modified(old)) > Self.maximumAge {
                try? fm.removeItem(at: old)
            }
        } catch {
            // A cache write failure must never prevent opening or editing an app.
        }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
