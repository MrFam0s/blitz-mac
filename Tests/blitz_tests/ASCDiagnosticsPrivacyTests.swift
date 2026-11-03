import Foundation
import Testing
@testable import Blitz

@MainActor
@Test func unrelatedDiagnosticSnapshotsDoNotPersistPrivateFeedbackErrors() {
    let manager = ASCManager()
    let privateFeedback = "Could not load tester@example.org: PRIVATE-TESTER-COMMENT"
    manager.tabError[.feedback] = privateFeedback
    manager.tabError[.builds] = "Build service unavailable"

    let snapshot = manager.diagnosticSnapshot(reason: "unrelated_tab_refresh_failed")

    #expect(!snapshot.contains("tester@example.org"))
    #expect(!snapshot.contains("PRIVATE-TESTER-COMMENT"))
    #expect(snapshot.contains(ASCTestFlightPrivacy.omittedErrorDescription))
    #expect(snapshot.contains("Build service unavailable"))
    #expect(manager.tabError[.feedback] == privateFeedback)
}
