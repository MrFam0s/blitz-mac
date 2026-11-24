import Testing
@testable import Blitz

@MainActor
@Test func returningToSimulatorTabLooksForExistingViewersWithoutOpeningOne() async throws {
    for accessibilityAllowed in [false, true] {
        let viewers = try await SimulatorStreamManager.windowViewers(openIfNeeded: false, accessibilityAllowed: accessibilityAllowed) {
            Issue.record("Tab navigation started a simulator viewer")
            throw SimulatorApplication.LaunchError.viewerUnavailable
        }
        #expect(viewers == (accessibilityAllowed ? [.deviceHub, .simulator] : [.simulator]))
    }
}

@MainActor
@Test func explicitSimulatorStartOpensThePreferredViewerOnce() async throws {
    var launches = 0
    let viewers = try await SimulatorStreamManager.windowViewers(openIfNeeded: true, accessibilityAllowed: true) {
        launches += 1
        return .simulator
    }
    #expect(launches == 1)
    #expect(viewers == [.simulator])
}
