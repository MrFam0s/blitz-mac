import Foundation
import Testing
@testable import Blitz

private let readinessTarget = ReleaseWorkflowTarget(projectID: "project", projectPath: "/tmp", appID: "app1",
    bundleID: "org.example.App", platform: "IOS", accountKey: "issuer:key", versionID: "version1", buildID: "build8")
private func historyVersion(_ id: String = "version1", platform: String = "IOS", state: String = "DEVELOPER_REJECTED", number: String = "1.2.0") -> [String: Any] {
    ["id": id, "attributes": ["platform": platform, "appStoreState": state, "versionString": number]]
}
private func readinessEvidence(status: String = "passed", reason: String = "current_program_license_active", bound: Bool = true) -> ReleaseWebEvidence {
    .init(appId: "app1", bundleId: "org.example.App", bindingVerified: bound, bindingReason: "web_provider_app_mismatch_or_inaccessible",
          appleId: "fixture@example.invalid", providerId: "PROVIDER", developerTeamId: "TEAM",
          programLicense: .init(status: status, reason: reason),
          businessFree: .init(status: "passed", reason: "current_business_agreement_active"),
          businessPaid: .init(status: "passed", reason: "current_business_agreement_active"))
}
private func readinessReport(checks: [[String: Any]] = [], deepChecks: [[String: Any]] = []) -> [String: Any] {
    ["appId": "app1", "versionId": "version1", "platform": "IOS", "checks": checks,
     "summary": ["blocking": checks.filter { $0["severity"] as? String != "info" }.count,
                 "warnings": checks.filter { $0["severity"] as? String == "warning" }.count],
     "deep": ["checks": deepChecks, "summary": ["blocked": deepChecks.filter { $0["status"] as? String == "blocked" }.count,
                                                "unverified": deepChecks.filter { $0["status"] as? String == "unverified" }.count]]]
}
private func normalize(_ report: [String: Any], first: Bool = true, web: ReleaseWebEvidence = readinessEvidence(),
                       localizations: [[String: Any]] = [["id": "de", "attributes": ["locale": "de-DE", "whatsNew": ""]]]) throws -> ReleaseWorkflowValidation {
    let blocking = (report["summary"] as? [String: Int])?["blocking"] ?? 0
    return try ReleaseReadinessPolicy.normalize(report: report, exitCode: blocking == 0 ? 0 : 1, target: readinessTarget,
        firstPublication: first, localizations: localizations, web: web, webBindingStable: web.matches(web, target: readinessTarget))
}

@Test func releaseReadinessFirstPublicationUsesPlatformHistoryNotNumberOrRejection() throws {
    #expect(try ReleaseReadinessPolicy.isFirstPublication(versions: [historyVersion()], target: readinessTarget))
    for state in ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE", "REPLACED_WITH_NEW_VERSION"] {
        #expect(try !ReleaseReadinessPolicy.isFirstPublication(versions: [historyVersion(number: "1.0"), historyVersion("old", state: state, number: "0.9")], target: readinessTarget))
        #expect(try ReleaseReadinessPolicy.isFirstPublication(versions: [historyVersion(), historyVersion("mac", platform: "MAC_OS", state: state)], target: readinessTarget))
    }
    #expect(throws: ReleaseWorkflowAPIError.self) {
        try ReleaseReadinessPolicy.isFirstPublication(versions: [historyVersion(), historyVersion("unknown", state: "NEW_APPLE_STATE")], target: readinessTarget)
    }
    #expect(throws: ReleaseWorkflowError.self) {
        try ReleaseReadinessPolicy.isFirstPublication(versions: [historyVersion("foreign")], target: readinessTarget)
    }
}

@Test func releaseReadinessRemovesOnlyProvenInitialWhatsNewWarnings() throws {
    let checks: [[String: Any]] = ["de-DE", "en-US"].map { ["id": "metadata.required.whats_new", "severity": "warning", "locale": $0] }
    let first = try normalize(readinessReport(checks: checks))
    #expect(first.ready && first.blocking == 0 && first.warnings == 0)
    #expect(first.diagnostics?.contains { $0.reason == "first_publication_verified_from_complete_platform_history" } == true)
    let trueUpdate = try normalize(readinessReport(), first: false)
    #expect(!trueUpdate.ready && trueUpdate.blocking == 1 && trueUpdate.warnings == 1)
    #expect(trueUpdate.diagnostics?.contains { $0.locale == "de-DE" && $0.reason == "published_platform_history_requires_changelog" } == true)
    let unrelated = try normalize(readinessReport(checks: checks + [["id": "screenshots.required", "severity": "error"]]))
    #expect(!unrelated.ready && unrelated.blocking == 1)
}

@Test func releaseReadinessActiveBusinessDoesNotStandInForProgramLicense() throws {
    let raw = readinessReport(checks: [["id": "deep.agreements.active.unverified", "severity": "warning"]],
        deepChecks: [["id": "agreements.active", "status": "unverified", "source": "webSession"]])
    let failedTeam = try normalize(raw, web: readinessEvidence(status: "unverified", reason: "developer_team_unresolved"))
    #expect(!failedTeam.ready && failedTeam.unverified == 1 && failedTeam.warnings == 0)
    #expect(failedTeam.diagnostics?.first { $0.id == "agreements.program_license" }?.guidance?.contains("Developer-Portal-Team") == true)
    #expect(failedTeam.diagnostics?.filter { $0.id.hasPrefix("agreements.business") }.allSatisfy { $0.status == "passed" } == true)
    let proven = try normalize(raw)
    #expect(proven.ready)
    let pending = try normalize(raw, web: readinessEvidence(status: "blocked", reason: "program_license_acceptance_required"))
    #expect(!pending.ready && pending.blocking == 1)
}

@Test func releaseReadinessRetainsFatalAgreementAlertsAndRejectsOtherProviderEvidence() throws {
    let blocked = try normalize(readinessReport(checks: [["id": "agreements.alert", "severity": "error"]],
        deepChecks: [["id": "agreements.active", "status": "blocked", "source": "webSession"]]))
    #expect(!blocked.ready && blocked.checkIDs.contains("agreements.alert") && blocked.blocking == 1)
    let wrongProvider = try normalize(readinessReport(deepChecks: [["id": "privacy.publish_state", "status": "passed", "source": "webSession"]]),
                                      web: readinessEvidence(bound: false))
    #expect(!wrongProvider.ready && wrongProvider.unverified == 4)
    #expect(wrongProvider.diagnostics?.first { $0.id == "privacy.publish_state" }?.status == "unverified")
}

@Test func releaseReadinessRejectsIncompleteSummariesAndUnexplainedFailure() throws {
    var partial = readinessReport(); partial["summary"] = ["blocking": 1, "warnings": 1]
    #expect(throws: ReleaseWorkflowAPIError.self) { try normalize(partial) }
    #expect(throws: ReleaseWorkflowAPIError.self) {
        try ReleaseReadinessPolicy.normalize(report: readinessReport(), exitCode: 2, target: readinessTarget,
            firstPublication: true, localizations: [], web: readinessEvidence(), webBindingStable: true)
    }
    let old = Data(#"{"ready":true,"blocking":0,"warnings":0,"unverified":0,"checkIDs":[]}"#.utf8)
    #expect(try JSONDecoder().decode(ReleaseWorkflowValidation.self, from: old).diagnostics == nil)
}

@Test func releaseReadinessSnapshotHistoryConsumesEveryPageAndRejectsForeignLinks() async throws {
    for foreign in [false, true] {
        var paths: [String] = []
        let adapter = ReleaseWorkflowASCAdapter(accountKey: "issuer:key", transport: { method, path, _, _ in
            #expect(method == "GET"); paths.append(path)
            let url = try #require(URLComponents(string: path))
            let object: [String: Any]
            switch url.path {
            case "/v1/apps/app1": object = ["data": ["id": "app1", "attributes": ["bundleId": "org.example.App"]]]
            case "/v1/apps/app1/appStoreVersions":
                if url.queryItems?.contains(where: { $0.name == "cursor" }) == true {
                    object = ["data": [historyVersion("removed", state: "DEVELOPER_REMOVED_FROM_SALE")]]
                } else {
                    object = ["data": [historyVersion()], "links": ["next": "https://\(foreign ? "foreign.invalid" : "api.appstoreconnect.apple.com")/v1/apps/app1/appStoreVersions?cursor=next"]]
                }
            case "/v1/appStoreVersions/version1/appStoreVersionLocalizations": object = ["data": [["id": "loc1", "attributes": ["locale": "de-DE"]]]]
            default: throw ReleaseWorkflowAPIError.invalidResponse
            }
            return ASCDaemonClient.HTTPResponse(statusCode: 200, headers: [:], contentType: "application/json",
                body: try JSONSerialization.data(withJSONObject: object))
        }, cli: { _ in throw ReleaseWorkflowAPIError.invalidResponse }, loadBuild: { _ in throw ReleaseWorkflowAPIError.invalidResponse },
        readinessReport: { _ in .init(report: try JSONSerialization.data(withJSONObject: readinessReport()), web: readinessEvidence(), exitCode: 0) })
        if foreign {
            await #expect(throws: ReleaseWorkflowAPIError.self) { try await adapter.readiness(readinessTarget) }
        } else {
            let result = try await adapter.readiness(readinessTarget)
            #expect(!result.ready && result.warnings == 1)
            #expect(paths.contains { $0.contains("cursor=next") })
        }
    }
}
