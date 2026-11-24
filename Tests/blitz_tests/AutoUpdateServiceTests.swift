import Foundation
import Testing
@testable import Blitz

@Test @MainActor func releaseCheckDistinguishesNoReleaseFromErrors() throws {
    let missing = try AutoUpdateManager.evaluateRelease(data: Data(), statusCode: 404, currentVersion: "1.0.71")
    guard case .unavailable = missing else { Issue.record("404 must explain the missing release"); return }
    for status in [401, 403, 429, 500] {
        #expect(throws: (any Error).self) {
            try AutoUpdateManager.evaluateRelease(data: Data(), statusCode: status, currentVersion: "1.0.71")
        }
    }
    #expect(throws: (any Error).self) {
        try AutoUpdateManager.evaluateRelease(data: Data("{}".utf8), statusCode: 200, currentVersion: "1.0.71")
    }
}

@Test @MainActor func releaseCheckOnlyOffersStableNewerInstallableVersions() throws {
    func response(_ version: String, assets: [[String: String]] = [], prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tag_name": version, "assets": assets, "prerelease": prerelease])
    }
    // An older release does not need downloadable assets to establish freshness.
    #expect(try AutoUpdateManager.evaluateRelease(data: response("v1.0.70"), statusCode: 200, currentVersion: "1.0.71") == .upToDate)
    let unavailable = try AutoUpdateManager.evaluateRelease(data: response("v1.0.72"), statusCode: 200, currentVersion: "1.0.71")
    guard case .unavailable = unavailable else { Issue.record("Missing assets need an explanation"); return }
    let assets = [["name": "BlitzNeo.app.zip", "browser_download_url": "https://github.com/MrFam0s/blitz-mac/releases/download/v1.0.72/BlitzNeo.app.zip"]]
    let available = try AutoUpdateManager.evaluateRelease(data: response("v1.0.72", assets: assets), statusCode: 200, currentVersion: "1.0.71")
    #expect(available == .available(.init(version: "1.0.72", downloadURL: assets[0]["browser_download_url"]!, filename: "BlitzNeo.app.zip")))
    let prerelease = try AutoUpdateManager.evaluateRelease(data: response("v1.0.72", assets: assets, prerelease: true), statusCode: 200, currentVersion: "1.0.71")
    guard case .unavailable = prerelease else { Issue.record("Prereleases must not be offered"); return }
    #expect(throws: (any Error).self) {
        try AutoUpdateManager.evaluateRelease(data: response("v1.0.broken"), statusCode: 200, currentVersion: "1.0.71")
    }
}

@Test @MainActor func updateCheckResultsDoNotBlockTheApp() {
    let manager = AutoUpdateManager()
    manager.state = .unavailable("No public release")
    #expect(!manager.showsFullScreenOverlay)
    manager.state = .checkFailed("Offline")
    #expect(!manager.showsFullScreenOverlay)
}

@Test @MainActor func changelogMatchesExactVersionWithOrWithoutBuildNumber() {
    let changelog = """
    ## 1.0.84 (build 104)
    - Manual simulator startup
    ## 1.0.80 (build 100)
    - Latest build notes
    ## 1.0.80 (build 99)
    - Previous build notes
    ## 1.0.79
    - Dashboard improvements
    """
    #expect(AutoUpdateManager.parseChangelog(changelog, version: "1.0.84") == "- Manual simulator startup")
    #expect(AutoUpdateManager.parseChangelog(changelog, version: "1.0.80") == "- Latest build notes")
    #expect(AutoUpdateManager.parseChangelog(changelog, version: "1.0.79") == "- Dashboard improvements")
    #expect(AutoUpdateManager.parseChangelog(changelog, version: "1.0.8").isEmpty)
}

@Test @MainActor func testAppUpdateInstallScriptKeepsBundleGuardsAndFailsOnScriptErrors() {
    let zipPath = URL(fileURLWithPath: "/tmp/Blitz.app.zip")
    let script = AutoUpdateManager.appUpdateInstallScript(zipPath: zipPath)

    #expect(!script.contains("/usr/bin/codesign --verify --deep --strict"))
    #expect(!script.contains("/usr/sbin/spctl --assess --verbose=4"))
    #expect(script.contains("CFBundleIdentifier"))
    #expect(script.contains("Contents/Helpers/ascd"))
    #expect(script.contains("BLITZ_UPDATE_CONTEXT='auto-update'"))
    #expect(!script.contains("PREINSTALL\\\" '' '' '/' >> \\\"$UPDATE_LOG\\\" 2>&1 || true"))
    #expect(!script.contains("POSTINSTALL\\\" '' '' '/' >> \\\"$UPDATE_LOG\\\" 2>&1 || true"))
}
