import Foundation
import Testing
@testable import Blitz

@Test func buildResponseDecodesMixedIncludedTypesAndExactIdentity() throws {
    let json = #"""
    {"data":{"id":"build-4","type":"builds","attributes":{"version":"42","processingState":"VALID","expired":false},"relationships":{"app":{"data":{"type":"apps","id":"app-1"}},"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"train-2"}}}},"included":[{"type":"apps","id":"app-1","attributes":{"name":"Example","bundleId":"org.example.App"}},{"type":"preReleaseVersions","id":"train-2","attributes":{"version":"2.0","platform":"MAC_OS"}}]}
    """#
    let response = try JSONDecoder().decode(ASCBuildResponse.self, from: Data(json.utf8))
    let build = try #require(response.build)
    #expect(build.matchesRelease(appId: "app-1", versionString: "2.0", platform: .macOS))
    #expect(!build.matchesRelease(appId: "app-1", versionString: "2.0", platform: .iOS))
    #expect(!build.matchesRelease(appId: "app-2", versionString: "2.0", platform: .macOS))
    #expect(!build.matchesRelease(appId: "app-1", versionString: "2.1", platform: .macOS))
}

@Test func buildListHydrationKeepsNextPageAndMissingIdentityFailsClosed() throws {
    let json = #"""
    {"data":[{"id":"b1","type":"builds","attributes":{"version":"1","processingState":"VALID"},"relationships":{"preReleaseVersion":{"data":{"id":"train"}}}}],"included":[{"id":"train","type":"preReleaseVersions","attributes":{"version":"1.0","platform":"IOS"}}],"links":{"next":"https://api.appstoreconnect.apple.com/v1/builds?cursor=next"}}
    """#
    let response = try JSONDecoder().decode(ASCBuildListResponse.self, from: Data(json.utf8))
    #expect(response.links?.next?.hasSuffix("cursor=next") == true)
    #expect(response.builds.first?.preReleaseVersion?.attributes.version == "1.0")
    #expect(response.builds.first?.matchesRelease(appId: "app", versionString: "1.0", platform: .iOS) == false)
}

@Test func nullAttachedBuildIsDecodedAsMissing() throws {
    let response = try JSONDecoder().decode(ASCBuildResponse.self, from: Data(#"{"data":null}"#.utf8))
    #expect(response.build == nil)
}

@MainActor @Test func unlinkedStoreAppInfersOnlyUnambiguousPlatform() {
    func version(_ id: String, _ platform: String) -> ASCAppStoreVersion {
        ASCAppStoreVersion(id: id, attributes: .init(versionString: "1.0", appStoreState: "READY_FOR_SALE", releaseType: nil, createdDate: nil, copyright: nil, platform: platform))
    }
    let manager = ASCManager()
    manager.loadedProjectId = "asc:org.example.App"
    manager.appStoreVersions = [version("mac", "MAC_OS")]
    #expect(manager.releasePlatform == .macOS)
    #expect(manager.releaseVersions.map(\.id) == ["mac"])
    manager.appStoreVersions.append(version("ios", "IOS"))
    #expect(manager.releasePlatform == nil)
    #expect(manager.releaseVersions.isEmpty)
    manager.selectReleasePlatform(.macOS)
    #expect(manager.releaseVersions.map(\.id) == ["mac"])
}

@Test func missingResponseDataIsNotMistakenForAbsentReviewOrBuild() throws {
    let missing = Data(#"{}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ASCBuildResponse.self, from: missing) }
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ASCReviewDetailResponse.self, from: missing) }
    let explicitNull = Data(#"{"data":null}"#.utf8)
    #expect(try JSONDecoder().decode(ASCReviewDetailResponse.self, from: explicitNull).data == nil)
    #expect(try JSONDecoder().decode(ASCBuildResponse.self, from: explicitNull).data == nil)
}
