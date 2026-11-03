import Foundation
import Testing
@testable import Blitz

struct MCPReleaseApprovalTests {
    private func target(project: String = "app-A", revision: UUID,
                        account: String = "account-A", version: String? = "version-A",
                        app: String? = "store-A", credentialRevision: Int = 1) -> MCPReleaseRequestTarget {
        MCPReleaseRequestTarget(projectID: project, projectPath: "/projects/\(project)",
            bundleID: "org.example.\(project)", platform: "iOS", appID: app,
            projectRevision: revision, credentialRevision: credentialRevision, accountKey: account,
            selectedVersionID: version)
    }

    @Test func approvalRejectsChangedProjectAccountOrVersion() {
        let revision = UUID()
        let original = target(revision: revision)
        #expect(original.matches(target(revision: revision)))
        #expect(!original.matches(target(project: "app-B", revision: revision)))
        #expect(!original.matches(target(revision: revision, account: "account-B")))
        #expect(!original.matches(target(revision: revision, version: "version-B")))
        #expect(!original.matches(target(revision: revision, app: "store-B")))
        // Switching away and back must not revive an earlier approval.
        #expect(!original.matches(target(revision: UUID())))
    }

    @Test func approvalAllowsInitialHydrationWithoutChangingCapturedIdentity() {
        let revision = UUID()
        let unloaded = target(revision: revision, version: nil, app: nil)
        #expect(unloaded.matches(target(revision: revision)))
        #expect(!unloaded.matches(target(project: "app-B", revision: revision)))
        #expect(!unloaded.matches(target(revision: revision, account: "account-B")))
    }

    @Test func credentialReactivationInvalidatesApprovalEvenForSameAccount() {
        let revision = UUID()
        let original = target(revision: revision)
        #expect(!original.matches(target(revision: revision, credentialRevision: 2)))
        // Initial app/version hydration is not permission to reuse approval after
        // credentials were saved again while its dialog was open.
        let unloaded = target(revision: revision, version: nil, app: nil)
        #expect(!unloaded.matches(target(revision: revision, credentialRevision: 2)))
    }

    @Test func uploadRegistryRequiresExplicitArtifactAndPreviewIsReadOnly() throws {
        let tools = MCPRegistry.allTools()
        let upload = try #require(tools.first { $0["name"] as? String == "app_store_upload" })
        let schema = try #require(upload["inputSchema"] as? [String: Any])
        #expect((schema["required"] as? [String])?.contains("ipaPath") == true)
        let preview = try #require(tools.first { $0["name"] as? String == "asc_open_submit_preview" })
        #expect((preview["description"] as? String)?.contains("Does not attach a build") == true)
    }
}
