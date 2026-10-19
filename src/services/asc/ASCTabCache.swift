import CryptoKit
import Foundation

/// Persist only server metadata. Local drafts, tracks, tester feedback and
/// credentials are never encoded in a tab snapshot.
struct ASCTabCacheEntry: Codable {
    let schema: Int
    let savedAt: Date
    let tab: String
    let appId: String
    let versionId: String?
    var app: ASCApp?
    var versions: [ASCAppStoreVersion]?
    var localizations: [ASCVersionLocalization]?
    var appInfo: ASCAppInfo?
    var infoLocalizations: [String: ASCAppInfoLocalization]?
    var screenshotSets: [String: [ASCScreenshotSet]]?
    var screenshots: [String: [String: [ASCScreenshot]]]?
    var builds: [ASCBuild]?
    var groups: [ASCBetaGroup]?
    var betaInfo: [ASCBetaLocalization]?

    @MainActor
    init?(manager: ASCManager, tab: AppTab, savedAt: Date = Date()) {
        guard Self.tabs.contains(tab), let currentApp = manager.app else { return nil }
        schema = 1
        self.savedAt = savedAt
        self.tab = tab.rawValue
        appId = currentApp.id
        versionId = Self.versionScoped.contains(tab) ? manager.selectedVersion?.id : nil
        switch tab {
        case .appInformation:
            app = currentApp
            versions = manager.appStoreVersions
            localizations = manager.localizations
            appInfo = manager.appInfo
            infoLocalizations = manager.appInfoLocalizationsByLocale
        case .screenshots:
            localizations = manager.localizations
            let prefix = "\(versionId ?? "current")::"
            screenshotSets = manager.screenshotSetsByLocale.filter { $0.key.hasPrefix(prefix) }
            screenshots = manager.screenshotsByLocale.filter { $0.key.hasPrefix(prefix) }
        case .builds: builds = manager.builds
        case .groups: groups = manager.betaGroups
        case .betaInfo: betaInfo = manager.betaLocalizations
        default: return nil
        }
    }

    static let tabs: Set<AppTab> = [.appInformation, .screenshots, .builds, .groups, .betaInfo]
    static let versionScoped: Set<AppTab> = [.appInformation, .screenshots]

    @MainActor @discardableResult
    func apply(to manager: ASCManager, tab: AppTab) -> Bool {
        guard schema == 1, self.tab == tab.rawValue, appId == manager.app?.id,
              !Self.versionScoped.contains(tab) || versionId == manager.selectedVersion?.id else { return false }
        switch tab {
        case .appInformation:
            guard let app, let versions, let localizations, let infoLocalizations else { return false }
            manager.app = app
            manager.appStoreVersions = versions
            manager.localizations = localizations
            manager.appInfo = appInfo
            manager.appInfoLocalizationsByLocale = infoLocalizations
            manager.appInfoLocalization = manager.primaryAppInfoLocalization(in: Array(infoLocalizations.values))
        case .screenshots:
            guard let localizations, let screenshotSets, let screenshots else { return false }
            manager.localizations = localizations
            manager.screenshotSetsByLocale.merge(screenshotSets) { _, new in new }
            manager.screenshotsByLocale.merge(screenshots) { _, new in new }
            for locale in localizations.map(\.attributes.locale) {
                for displayType in manager.orderedKnownScreenshotDisplayTypes(for: locale) {
                    manager.loadTrackFromASC(displayType: displayType, locale: locale)
                }
            }
        case .builds:
            guard let builds else { return false }; manager.builds = builds
        case .groups:
            guard let groups else { return false }; manager.betaGroups = groups
        case .betaInfo:
            guard let betaInfo else { return false }; manager.betaLocalizations = betaInfo
        default: return false
        }
        manager.loadedTabs.insert(tab)
        manager.tabLoadedAt[tab] = savedAt
        manager.tabsNeedingRevalidation.insert(tab)
        return true
    }
}

actor ASCTabCache {
    static let shared = ASCTabCache()
    static let maximumAge: TimeInterval = 7 * 86400
    static let maximumEntries = 120
    static let maximumEntryBytes = 2 * 1024 * 1024
    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.blitz.macos/asc-tabs", isDirectory: true)) { self.directory = directory }

    private func url(account: String, appId: String, tab: String, versionId: String?) -> URL {
        let key = [account, appId, tab, versionId ?? ""].joined(separator: "\u{0}")
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }

    func load(account: String, appId: String, tab: AppTab, versionId: String?, now: Date = Date()) -> ASCTabCacheEntry? {
        let file = url(account: account, appId: appId, tab: tab.rawValue, versionId: versionId)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maximumEntryBytes,
              let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(ASCTabCacheEntry.self, from: data),
              entry.schema == 1, entry.appId == appId, entry.tab == tab.rawValue, entry.versionId == versionId,
              (-60...Self.maximumAge).contains(now.timeIntervalSince(entry.savedAt)) else { return nil }
        return entry
    }

    func save(_ entry: ASCTabCacheEntry, account: String) {
        guard let bytes = try? JSONEncoder().encode(entry), bytes.count <= Self.maximumEntryBytes else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = url(account: account, appId: entry.appId, tab: entry.tab, versionId: entry.versionId)
            try bytes.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" }.sorted { modified($0) > modified($1) }
            for (index, old) in files.enumerated()
                where index >= Self.maximumEntries || Date().timeIntervalSince(modified(old)) > Self.maximumAge {
                try? fm.removeItem(at: old)
            }
        } catch { /* Cache failures never block the editor. */ }
    }

    private func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
