import Foundation
import Testing
@testable import Blitz

@Suite struct RegisteredReleaseTargetTests {
    private let bundle = "org.example.SharedApp"
    private var path: String { FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path }

    private func project(selected: String = "ios", binding: ProjectStoreBinding? = nil) -> Project {
        let store = binding ?? ProjectStoreBinding(appId: "shared-app", accountKey: "issuer:key", bundleIdentifier: bundle)
        let targets = [
            ProjectReleaseTarget(id: "ios", platform: .iOS, bundleIdentifier: bundle,
                                 buildSettings: .init(scheme: "Mobile"), storeBinding: store),
            ProjectReleaseTarget(id: "mac", platform: .macOS, bundleIdentifier: bundle,
                                 buildSettings: .init(scheme: "Desktop"), storeBinding: store)
        ]
        return Project(id: "project", metadata: .init(name: "Shared App", type: .swift,
            releaseTargets: targets, selectedReleaseTargetId: selected), path: path)
    }

    private func target(id: String? = "mac") -> ReleaseWorkflowTarget {
        ReleaseWorkflowTarget(projectID: "project", projectPath: path, appID: "shared-app", bundleID: bundle,
            platform: "MAC_OS", accountKey: "issuer:key", versionID: "mac-version", buildID: "mac-build", releaseTargetID: id)
    }

    @Test func explicitNativePlatformIsIndependentOfUISelection() throws {
        let registered = project(selected: "ios")
        try RegisteredReleaseTarget.verify(target(), project: registered)
        let mac = try RegisteredReleaseTarget.resolve(project: registered, releaseTargetID: "mac",
            appID: "shared-app", bundleID: bundle, platform: "MAC_OS", accountKey: "issuer:key")
        #expect(mac.buildSettings?.scheme == "Desktop")
        #expect(registered.metadata.selectedReleaseTarget?.id == "ios")
    }

    @Test func missingTargetNeverUsesSelectedPlatformOfAmbiguousProject() {
        #expect(throws: ProjectReleaseTargetError.self) {
            try RegisteredReleaseTarget.verify(target(id: nil), project: project(selected: "mac"))
        }
        #expect(throws: ProjectReleaseTargetError.self) {
            try RegisteredReleaseTarget.verify(target(id: "not-configured"), project: project())
        }
    }

    @Test func storedAppAccountBundleAndPlatformMustAllMatch() {
        for values in [("other-app", bundle, "MAC_OS", "issuer:key"),
                       ("shared-app", bundle.lowercased(), "MAC_OS", "issuer:key"),
                       ("shared-app", bundle, "IOS", "issuer:key"),
                       ("shared-app", bundle, "MAC_OS", "other:key")] {
            #expect(throws: Error.self) {
                try RegisteredReleaseTarget.resolve(project: project(), releaseTargetID: "mac", appID: values.0,
                    bundleID: values.1, platform: values.2, accountKey: values.3)
            }
        }
    }

    @Test func changedRegistrationInvalidatesSavedOperation() {
        let changed = project(binding: .init(appId: "different-app", accountKey: "issuer:key", bundleIdentifier: bundle))
        #expect(throws: Error.self) { try RegisteredReleaseTarget.verify(target(), project: changed) }
        let moved = Project(id: "project", metadata: project().metadata, path: path + "/moved")
        #expect(throws: Error.self) { try RegisteredReleaseTarget.verify(target(), project: moved) }
    }

    @Test func unboundNonlegacyAndDuplicateTargetIDsAreRejected() {
        var unbound = project()
        unbound.metadata.releaseTargets?[1].storeBinding = nil
        #expect(throws: Error.self) { try RegisteredReleaseTarget.verify(target(), project: unbound) }
        var duplicate = project()
        duplicate.metadata.releaseTargets?[0].id = "mac"
        #expect(throws: Error.self) { try RegisteredReleaseTarget.verify(target(), project: duplicate) }
    }

    @Test func legacyRequestRemainsCompatibleOnlyWhileTargetIsUnambiguous() throws {
        var legacy = Project(id: "project", metadata: .init(name: "Legacy", type: .swift,
            platform: .macOS, bundleIdentifier: bundle), path: path)
        try RegisteredReleaseTarget.verify(target(id: nil), project: legacy)
        try RegisteredReleaseTarget.verify(target(id: "legacy"), project: legacy)
        legacy.metadata.materializeReleaseTargets()
        legacy.metadata.releaseTargets?.append(ProjectReleaseTarget(id: "ios", platform: .iOS, bundleIdentifier: bundle))
        #expect(throws: Error.self) { try RegisteredReleaseTarget.verify(target(id: nil), project: legacy) }
        #expect(throws: Error.self) { try RegisteredReleaseTarget.verify(target(id: "legacy"), project: legacy) }
    }

    @Test func oldEncodedTargetsKeepTheirShapeAndNewTargetIDChangesDigest() throws {
        let encoder = JSONEncoder()
        let old = target(id: nil)
        let oldData = try encoder.encode(old)
        let oldJSON = try #require(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        #expect(oldJSON["releaseTargetId"] == nil)
        #expect(try JSONDecoder().decode(ReleaseWorkflowTarget.self, from: oldData) == old)
        let updated = target()
        let updatedJSON = try #require(JSONSerialization.jsonObject(with: encoder.encode(updated)) as? [String: Any])
        #expect(updatedJSON["releaseTargetId"] as? String == "mac")
        #expect(try ReleaseWorkflowService.digest(old) != ReleaseWorkflowService.digest(updated))
        #expect(try ReleaseWorkflowService.digest(target(id: "ios")) != ReleaseWorkflowService.digest(updated))
    }

    @Test func handoffPinsTargetAndDoesNotSurviveTargetSelectionChange() throws {
        let app = ASCApp(id: "shared-app", attributes: .init(bundleId: bundle, name: "Shared App",
            primaryLocale: nil, vendorNumber: nil, contentRightsDeclaration: nil), relationships: nil)
        let context = ReleaseAutomationContext(projectID: "project", projectPath: path, appID: "shared-app",
            appName: "Shared App", bundleID: bundle, platform: .macOS, displayedLiveVersion: nil,
            accountKey: "issuer:key", releaseTargetID: "mac")
        #expect(context.matches(project: project(selected: "mac"), app: app))
        #expect(!context.matches(project: project(selected: "ios"), app: app))
        let data = try JSONEncoder().encode(context)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["releaseTargetId"] as? String == "mac")
        #expect(try JSONDecoder().decode(ReleaseAutomationContext.self, from: data) == context)
    }
}
