import Foundation
import Testing
@testable import Blitz

private actor ScopedWriteRecorder {
    var paths: [String] = []
    func append(_ path: String) { paths.append(path) }
}

private actor ScopedDraftTransport {
    static let live = #"{"id":"live","attributes":{"versionString":"1.0","appStoreState":"READY_FOR_SALE","platform":"IOS","releaseType":"MANUAL"}}"#
    static let draft = #"{"id":"draft","attributes":{"versionString":"1.1","appStoreState":"PREPARE_FOR_SUBMISSION","platform":"IOS","releaseType":"MANUAL"}}"#
    static let locale = #"{"id":"locale","attributes":{"locale":"de-DE","description":"Existing description"}}"#
    var created = false
    var mutations: [String] = []
    func request(_ method: String, _ path: String) throws -> ASCDaemonClient.HTTPResponse {
        let endpoint = URLComponents(string: path)?.path ?? path
        let body: String
        switch (method, endpoint) {
        case ("GET", "/v1/apps/app-a/appStoreVersions"):
            body = "{\"data\":[" + (created ? Self.draft + "," : "") + Self.live + "]}"
        case ("GET", "/v1/appStoreVersions/live/appStoreVersionLocalizations"):
            body = "{\"data\":[" + Self.locale + "]}"
        case ("POST", "/v1/appStoreVersions"):
            mutations.append("create"); created = true; body = "{\"data\":" + Self.draft + "}"
        case ("POST", "/v1/appStoreVersionLocalizations"):
            mutations.append("copy"); body = "{\"data\":" + Self.locale + "}"
        default: throw ASCError.notFound("Unexpected fixture request: \(method) \(endpoint)")
        }
        return .init(statusCode: 200, headers: [:], contentType: "application/json", body: Data(body.utf8))
    }
}

@MainActor private final class ExpectedTargetFixture {
    var selected = "app-a"
    func check() throws {
        guard selected == "app-a" else { throw MCPBoundRequestError.targetChanged }
    }
}

struct MCPExpectedTargetTests {
    private func json(version: Any = "version-a") -> [String: Any] {
        ["projectId": "project-a", "projectPath": "/projects/a", "appId": "app-a",
         "bundleId": "org.example.A", "platform": "iOS", "accountKey": "account-a", "versionId": version]
    }
    private func capture(version: String? = "version-a", project: String = "project-a", app: String = "app-a",
                         bundle: String = "org.example.A", account: String = "account-a", path: String = "/projects/a",
                         platform: String = "iOS") -> MCPReleaseRequestTarget {
        MCPReleaseRequestTarget(projectID: project, projectPath: path, bundleID: bundle,
            platform: platform, appID: app, projectRevision: UUID(), credentialRevision: 1,
            accountKey: account, selectedVersionID: version)
    }

    @Test func callerTargetNeverAdoptsAChangedSelection() throws {
        let target = try MCPExpectedTarget(json: json())
        #expect(target.matches(capture()))
        #expect(!target.matches(capture(project: "project-b")))
        #expect(!target.matches(capture(app: "app-b")))
        #expect(!target.matches(capture(bundle: "org.example.B")))
        #expect(!target.matches(capture(account: "account-b")))
        #expect(!target.matches(capture(path: "/projects/b")))
        #expect(!target.matches(capture(platform: "macOS")))
        #expect(!target.matches(capture(version: "version-b")))
        #expect(!target.matches(capture(version: nil)))
    }

    @Test func noVersionIsExplicitAndDoesNotAuthorizeLaterHydration() throws {
        let target = try MCPExpectedTarget(json: json(version: NSNull()))
        #expect(target.matches(capture(version: nil)))
        #expect(!target.matches(capture()))
        var missing = json(); missing.removeValue(forKey: "versionId")
        #expect(throws: MCPBoundRequestError.self) { try MCPExpectedTarget(json: missing) }
        #expect(throws: MCPBoundRequestError.self) { try MCPExpectedTarget(json: json(version: "")) }
    }

    @Test func targetRoundTripsWithoutExposingCredentials() throws {
        let original = try MCPExpectedTarget(captured: capture())
        let encoded = try JSONSerialization.data(withJSONObject: original.json)
        let decoded = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(try MCPExpectedTarget(json: decoded) == original)
        #expect(Set(decoded.keys) == Set(["projectId", "projectPath", "appId", "bundleId", "platform", "accountKey", "versionId"]))
        for field in ["projectId", "projectPath", "appId", "bundleId", "platform", "accountKey"] {
            var invalid = json(); invalid.removeValue(forKey: field)
            #expect(throws: MCPBoundRequestError.self) { try MCPExpectedTarget(json: invalid) }
        }
    }

    @Test func deliberateVersionTransitionCannotAdoptAnotherOwner() {
        let original = capture()
        let transitioned = MCPReleaseRequestTarget(projectID: original.projectID, projectPath: original.projectPath,
            bundleID: original.bundleID, platform: original.platform, appID: original.appID,
            projectRevision: original.projectRevision, credentialRevision: original.credentialRevision,
            accountKey: original.accountKey, selectedVersionID: "new-draft")
        #expect(original.matchesOwner(transitioned))
        #expect(!original.matches(transitioned))
        #expect(!original.matchesOwner(capture(project: "project-b")))
        #expect(!original.matchesOwner(capture(account: "account-b")))
    }

    @Test func allStoreWritesRequireContextButIdentityRecoveryRemainsUsable() {
        for name in ["asc_fill_form", "asc_select_version", "asc_create_version", "screenshots_save",
                     "asc_set_app_price", "asc_create_iap", "app_store_setup_signing", "app_store_upload"] {
            #expect(MCPExpectedTarget.requiresBinding(tool: name, arguments: [:]))
        }
        for name in ["asc_set_credentials", "asc_web_auth", "asc_confirm_created_app", "asc_reopen_app_setup", "get_tab_state"] {
            #expect(!MCPExpectedTarget.requiresBinding(tool: name, arguments: [:]))
        }
        #expect(!MCPExpectedTarget.requiresBinding(tool: "asc_fill_form", arguments: ["tab": "settings.bundleId"]))
    }

    @Test @MainActor func aBatchStopsBeforeItsSecondWriteWhenTheUIChanges() async throws {
        let fixture = ExpectedTargetFixture()
        let recorder = ScopedWriteRecorder()
        let scope = MCPMutationScope { try fixture.check() }
        let service = AppStoreConnectService(requestTransport: { _, path, _, _ in
            await recorder.append(path)
            await MainActor.run { fixture.selected = "app-b" }
            return .init(statusCode: 204, headers: [:], contentType: "application/json", body: Data())
        })
        await MCPMutationScope.$current.withValue(scope) {
            do {
                try await service.patchLocalization(id: "localization-a", fields: ["description": "First"])
                try await service.patchApp(id: "app-b", fields: ["contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"])
                Issue.record("A changed target allowed the second network mutation")
            } catch {
                #expect(error is MCPBoundRequestError)
            }
        }
        #expect(await recorder.paths == ["/v1/appStoreVersionLocalizations/localization-a"])
    }

    @Test @MainActor func inheritedChildCannotWriteAfterItsOperationFinishes() async {
        let scope = MCPMutationScope { }
        let recorder = ScopedWriteRecorder()
        let service = AppStoreConnectService(requestTransport: { _, path, _, _ in
            await recorder.append(path)
            return .init(statusCode: 204, headers: [:], contentType: "application/json", body: Data())
        })
        await MCPMutationScope.$current.withValue(scope) {
            // Existing manager Tasks inherit the scope even after the parent returns.
            let child = Task {
                scope.finish()
                do {
                    try await service.deleteScreenshot(screenshotId: "screenshot-a")
                    Issue.record("Delayed child performed a mutation after the scope expired")
                } catch { #expect(error is MCPBoundRequestError) }
            }
            await child.value
        }
        #expect(await recorder.paths.isEmpty)
    }

    @Test func directUIRequestsDoNotNeedAnExternalChatContext() async throws {
        let recorder = ScopedWriteRecorder()
        let service = AppStoreConnectService(requestTransport: { _, path, _, _ in
            await recorder.append(path)
            return .init(statusCode: 204, headers: [:], contentType: "application/json", body: Data())
        })
        try await service.deleteScreenshot(screenshotId: "screenshot-a")
        #expect(await recorder.paths == ["/v1/appScreenshots/screenshot-a"])
    }

    @Test @MainActor func versionCreationCopiesBeforeItsAuthorizedSelectionChange() async throws {
        let manager = ASCManager()
        manager.app = ASCApp(id: "app-a", attributes: .init(bundleId: "org.example.A", name: "A",
            primaryLocale: "de-DE", vendorNumber: nil, contentRightsDeclaration: nil), relationships: nil)
        manager.appStoreVersions = [try JSONDecoder().decode(ASCAppStoreVersion.self, from: Data(ScopedDraftTransport.live.utf8))]
        manager.selectedVersionId = "live"
        let transport = ScopedDraftTransport()
        let service = AppStoreConnectService(requestTransport: { method, path, _, _ in
            try await transport.request(method, path)
        })
        let scope = MCPMutationScope {
            guard manager.selectedVersionId == "live" else { throw MCPBoundRequestError.targetChanged }
        }
        let created = await MCPMutationScope.$current.withValue(scope) {
            await manager.createUpdateVersion(versionString: "1.1", platform: .iOS,
                copyFromVersionId: "live", copyReviewDetail: false, using: service)
        }
        #expect(created?.id == "draft")
        #expect(manager.selectedVersionId == "draft")
        #expect(await transport.mutations == ["create", "copy"])
        #expect(manager.versionCreationError == nil)
    }
}
