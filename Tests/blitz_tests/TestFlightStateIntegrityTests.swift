import Foundation
import Testing
@testable import Blitz

@Test func testFlightBuildStateKeepsAllIdentitiesExpiryAndBetaStatus() throws {
    func build(_ index: Int) throws -> ASCBuild {
        let json = """
        {"id":"build-\(index)","attributes":{"version":"7","processingState":"VALID","expired":\(index == 0)},"relationships":{"app":{"data":{"id":"app-a"}}},"preReleaseVersion":{"id":"train-\(index)","attributes":{"version":"\(index < 10 ? "1.0" : "2.0")","platform":"\(index % 2 == 0 ? "IOS" : "MAC_OS")"}},"buildBetaDetail":{"id":"detail-\(index)","attributes":{"internalBuildState":"IN_BETA_TESTING","externalBuildState":"WAITING_FOR_BETA_REVIEW","autoNotifyEnabled":false}}}
        """
        return try JSONDecoder().decode(ASCBuild.self, from: Data(json.utf8))
    }
    let payload = MCPExecutor.testFlightBuildListPayload(try (0..<21).map(build))
    let builds = try #require(payload["builds"] as? [[String: Any]])
    #expect(builds.count == 21)
    #expect(payload["totalBuilds"] as? Int == 21)
    #expect(payload["truncated"] as? Bool == false)
    #expect(builds[0]["buildNumber"] as? String == "7")
    #expect(builds[0]["marketingVersion"] as? String == "1.0")
    #expect(builds[20]["marketingVersion"] as? String == "2.0")
    #expect(builds[1]["platform"] as? String == "MAC_OS")
    #expect(builds[0]["expired"] as? Bool == true)
    #expect(builds[0]["externalBuildState"] as? String == "WAITING_FOR_BETA_REVIEW")
    #expect(builds[0]["autoNotifyEnabled"] as? Bool == false)
    #expect(JSONSerialization.isValidJSONObject(payload))
}

@Test func testFlightUnknownIdentityAndAnonymousTesterStayUnknown() throws {
    let build = try JSONDecoder().decode(ASCBuild.self, from: Data(#"{"id":"b","attributes":{"version":"1"}}"#.utf8))
    let payload = MCPExecutor.testFlightBuildPayload(build)
    #expect(payload["expired"] is NSNull)
    #expect(payload["platform"] is NSNull)
    #expect(payload["externalBuildState"] is NSNull)
    let tester = try JSONDecoder().decode(ASCBetaTester.self, from: Data(#"{"id":"public-tester"}"#.utf8))
    let testerPayload = MCPExecutor.testFlightTesterPayload(tester)
    #expect(testerPayload["id"] as? String == "public-tester")
    #expect(testerPayload["email"] is NSNull)
    #expect(JSONSerialization.isValidJSONObject(testerPayload))
}

@MainActor @Test func testFlightReadTargetRejectsAppAccountAndAwayBackSwitches() throws {
    let manager = ASCManager()
    manager.loadedProjectId = "project-a"
    manager.app = try JSONDecoder().decode(ASCApp.self, from: Data(#"{"id":"a","attributes":{"name":"Example","bundleId":"org.example.App"}}"#.utf8))
    let target = ASCTabReadTarget(manager)
    #expect(target.matches(manager))
    manager.credentialActivationRevision += 1
    #expect(!target.matches(manager))
    manager.credentialActivationRevision -= 1
    let original = manager.projectRevision
    manager.projectRevision = UUID()
    #expect(!target.matches(manager))
    manager.projectRevision = original
    manager.loadedProjectId = "project-b"
    #expect(!target.matches(manager))
}

@Test func betaInfoChangesDistinguishClearFromUnchanged() {
    let old = ["Old description", "tester@example.com", "https://example.com", "https://example.com/privacy"]
    #expect(ASCBetaInfoChanges.fields(original: old, edited: old).isEmpty)
    let fields = ASCBetaInfoChanges.fields(original: old, edited: ["New description", old[1], "", old[3]])
    #expect(fields == ["description": "New description", "marketingUrl": ""])
    #expect(fields["privacyPolicyUrl"] == nil)
    #expect(ASCBetaInfoChanges.fields(original: [], edited: old).isEmpty)
}

@Test func generatedTestFlightGuideMigrationPreservesUserContentAndIsIdempotent() {
    let original = """
    ## blitz-macos
    User workflow: always use our staging testers first.
    `asc testflight add-tester --email ...`
    ### app_store_upload
    | ipaPath | string | no | Path to IPA (uses latest app_store_build output if omitted) |
    Custom release notes remain here.
    """
    let updated = ProjectAgentConfigService.updatedLegacyTestFlightExamples(in: original)
    #expect(updated.contains("--app APP_ID --email EMAIL --group GROUP_ID"))
    #expect(updated.contains("| ipaPath | string | yes |"))
    #expect(updated.contains("User workflow: always use our staging testers first."))
    #expect(updated.contains("Custom release notes remain here."))
    #expect(ProjectAgentConfigService.updatedLegacyTestFlightExamples(in: updated) == updated)
    let custom = "User note: `asc testflight add-tester --email ...` failed last year."
    #expect(ProjectAgentConfigService.updatedLegacyTestFlightExamples(in: custom) == custom)
}
