import Foundation
import Testing
@testable import Blitz

private func changelogVersion(_ id: String, _ number: String, _ state: String, platform: String? = "IOS") -> ASCAppStoreVersion {
    ASCAppStoreVersion(id: id, attributes: .init(versionString: number, appStoreState: state,
        releaseType: nil, createdDate: nil, copyright: nil, platform: platform))
}

private func changelogLocalization(_ locale: String, notes: String?) -> ASCVersionLocalization {
    ASCVersionLocalization(id: locale, attributes: .init(locale: locale, title: nil,
        subtitle: nil, description: "Description", keywords: "test", promotionalText: nil,
        marketingUrl: nil, supportUrl: "https://example.com/support", whatsNew: notes))
}

@MainActor @Test func removedOrReplacedPredecessorRequiresNotesForEveryUpdateLocale() {
    for state in ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "REMOVED_FROM_SALE",
                  "DEVELOPER_REMOVED_FROM_SALE", "REPLACED_WITH_NEW_VERSION"] {
        let manager = ASCManager()
        manager.appStoreVersions = [changelogVersion("old", "1.9", state),
                                    changelogVersion("draft", "1.10", "PREPARE_FOR_SUBMISSION")]
        manager.selectedVersionId = "draft"
        manager.localizations = [changelogLocalization("de-DE", notes: " \n"),
                                 changelogLocalization("en-US", notes: nil),
                                 changelogLocalization("fr-FR", notes: "Corrections.")]
        #expect(manager.selectedVersionRequiresWhatsNew)
        #expect(manager.selectedVersionLocalizationsMissingWhatsNew().map(\.attributes.locale) == ["de-DE", "en-US"])
        let missing = Set(manager.submissionReadiness.missingRequired.map(\.label))
        #expect(missing.contains("What's New (de-DE)"))
        #expect(missing.contains("What's New (en-US)"))
        #expect(!missing.contains("What's New (fr-FR)"))
    }
}

@MainActor @Test func firstPlatformReleaseAndHistoricalRejectedDraftDoNotRequireNotes() {
    let manager = ASCManager()
    manager.appStoreVersions = [changelogVersion("ios-live", "1.0", "READY_FOR_SALE"),
                                changelogVersion("mac-first", "2.0", "PREPARE_FOR_SUBMISSION", platform: "MAC_OS")]
    manager.selectedVersionId = "mac-first"
    #expect(!manager.selectedVersionRequiresWhatsNew)
    manager.appStoreVersions = [changelogVersion("first-rejected", "1.0", "REJECTED"),
                                changelogVersion("draft", "1.1", "PREPARE_FOR_SUBMISSION")]
    manager.selectedVersionId = "draft"
    #expect(!manager.selectedVersionRequiresWhatsNew)
    manager.appStoreVersions = [changelogVersion("live", "1.1", "READY_FOR_SALE"),
                                changelogVersion("first-rejected", "1.0", "REJECTED")]
    manager.selectedVersionId = "first-rejected"
    #expect(!manager.selectedVersionRequiresWhatsNew)
}

@MainActor @Test func removedLegacyPredecessorStillRequiresNotesWithoutPlatformFields() {
    let manager = ASCManager()
    manager.appStoreVersions = [changelogVersion("old", "1.0", "REMOVED_FROM_SALE", platform: nil),
                                changelogVersion("draft", "1.1", "PREPARE_FOR_SUBMISSION", platform: nil)]
    manager.selectedVersionId = "draft"
    #expect(manager.selectedVersionRequiresWhatsNew)
}

@Test func repeatedExplicitReleaseRequestIsDeliveredToExistingTerminal() {
    var registry = AgentSessionRegistry()
    let releaseSession = UUID(), otherSession = UUID()
    registry.register(releaseSession, for: "release-A")
    registry.register(otherSession, for: "release-B")
    var delivered: [(UUID, [UInt8])] = []
    let request = "New release 1.2\nApp: org.example.App\nChangelog: changes since 1.1"
    let reused = registry.reuse(for: "release-A", activeIDs: [releaseSession, otherSession], prompt: request) {
        delivered.append(($0, TerminalAgentPromptInput.bytes(for: $1)))
    }
    #expect(reused == releaseSession)
    #expect(delivered.count == 1)
    #expect(delivered.first?.0 == releaseSession)
    #expect(delivered.first?.1 == Array(("\u{1b}[200~" + request + "\u{1b}[201~\r").utf8))
    // A further confirmed request stays in this conversation rather than starting
    // a parallel agent; the workflow reconciles the actual release lock/state.
    #expect(registry.reuse(for: "release-A", activeIDs: [releaseSession], prompt: "Recheck 1.2") {
        delivered.append(($0, TerminalAgentPromptInput.bytes(for: $1)))
    } == releaseSession)
    #expect(delivered.count == 2)
}

@Test func passiveTerminalOpenAndTerminatedReleaseNeverReceiveAnotherPrompt() {
    var registry = AgentSessionRegistry()
    let releaseSession = UUID()
    registry.register(releaseSession, for: "release")
    var deliveries = 0
    #expect(registry.existing(for: "release", activeIDs: [releaseSession]) == releaseSession)
    #expect(registry.reuse(for: "release", activeIDs: [releaseSession], prompt: nil) { _, _ in deliveries += 1 } == releaseSession)
    #expect(deliveries == 0)
    #expect(registry.reuse(for: "release", activeIDs: [], prompt: "Retry") { _, _ in deliveries += 1 } == nil)
    #expect(deliveries == 0)
    let replacement = UUID()
    registry.register(replacement, for: "release")
    #expect(registry.reuse(for: "release", activeIDs: [replacement], prompt: "Retry") { _, _ in deliveries += 1 } == replacement)
    #expect(deliveries == 1)
}

@Test func releasePromptPastePreservesMultilineShellTextWithoutControlInjection() {
    let text = "App's name\r\n$(touch /tmp/never-execute) `command`\rline\tvalue\u{1b}[201~\u{00}"
    let bytes = TerminalAgentPromptInput.bytes(for: text)
    let pasted = String(decoding: bytes, as: UTF8.self)
    #expect(pasted == "\u{1b}[200~App's name\n$(touch /tmp/never-execute) `command`\nline\tvalue\\u001B[201~\\u0000\u{1b}[201~\r")
    #expect(bytes.filter { $0 == 0x1b }.count == 2)
    #expect(bytes.filter { $0 == 0x0d }.count == 1)
}

@Test func releaseSessionIdentityIsStableAcrossDraftAndLiveVersionChanges() {
    let original = ReleaseAutomationContext(projectID: "project", projectPath: "/tmp/project",
        appID: "app", appName: "App", bundleID: "org.example.App", platform: .iOS, displayedLiveVersion: "1.0")
    var prepared = original
    prepared.preparedVersion = PreparedReleaseVersion(id: "draft", version: "1.1")
    let next = ReleaseAutomationContext(projectID: "project", projectPath: "/tmp/project",
        appID: "app", appName: "App", bundleID: "org.example.App", platform: .iOS, displayedLiveVersion: "1.1")
    let otherPlatform = ReleaseAutomationContext(projectID: "project", projectPath: "/tmp/project",
        appID: "app", appName: "App", bundleID: "org.example.App", platform: .macOS, displayedLiveVersion: "1.0")
    #expect(original.sessionKey == prepared.sessionKey)
    #expect(original.sessionKey == next.sessionKey)
    #expect(original.sessionKey != otherPlatform.sessionKey)
}

@Test func preparedReleaseIsScopedToCapturedPlatform() throws {
    let versions = [changelogVersion("ios-live", "1.0", "READY_FOR_SALE"),
                    changelogVersion("mac-draft", "2.0", "PREPARE_FOR_SUBMISSION", platform: "MAC_OS")]
    #expect(try ReleaseAutomationService.preparedVersion(in: versions, platform: .iOS) == nil)
    #expect(try ReleaseAutomationService.preparedVersion(in: versions, platform: .macOS)?.id == "mac-draft")
}
