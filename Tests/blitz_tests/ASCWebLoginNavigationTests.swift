import Foundation
import SwiftUI
import Testing
@testable import Blitz

@Test func webLoginIgnoresOldNavigationCompletionAndDeadline() throws {
    var navigation = ASCWebLoginNavigation()
    let oldToken = navigation.start()
    let old = try #require(oldToken)
    let currentToken = navigation.start()
    let current = try #require(currentToken)
    let oldFinished = navigation.finish(old)
    #expect(!oldFinished)
    let oldFailed = navigation.fail(old)
    #expect(!oldFailed)
    #expect(navigation.isLoading && !navigation.canValidate)
    let currentFinished = navigation.finish(current)
    #expect(currentFinished)
    #expect(!navigation.isLoading && navigation.canValidate)
}

@Test func webLoginDoesNotValidateTimedOutOrTerminatedPage() throws {
    var navigation = ASCWebLoginNavigation()
    let stalledToken = navigation.start()
    let stalled = try #require(stalledToken)
    let timedOut = navigation.fail(stalled)
    #expect(timedOut)
    #expect(!navigation.isLoading && !navigation.canValidate)
    let lateFinished = navigation.finish(stalled)
    #expect(!lateFinished)
    let recoveredToken = navigation.start()
    let recovered = try #require(recoveredToken)
    let recoveredFinished = navigation.finish(recovered)
    #expect(recoveredFinished)
    let terminated = navigation.fail(recovered) // Content process dies after loading.
    #expect(terminated)
    #expect(!navigation.canValidate)
    navigation.cancel()
    let cancelledStart = navigation.start()
    #expect(cancelledStart == nil)
    let cancelledFinish = navigation.finish(recovered)
    #expect(!cancelledFinish)
}

@Test func webLoginRetryAndAccountSwitchHaveDifferentStorageSemantics() throws {
    let suite = "BlitzWebLoginTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(ASCWebLoginStoreIdentity.current(in: defaults) == ASCWebLoginStoreIdentity.original)
    defaults.set("malformed", forKey: ASCWebLoginStoreIdentity.preferenceKey)
    #expect(ASCWebLoginStoreIdentity.current(in: defaults) == ASCWebLoginStoreIdentity.original)
    let cleanupA = ASCWebLoginStoreIdentity.rotate(in: defaults)
    let b = ASCWebLoginStoreIdentity.current(in: defaults)
    #expect(cleanupA == ASCWebLoginStoreIdentity.original)
    #expect(b != cleanupA)
    #expect(ASCWebLoginStoreIdentity.current(in: defaults) == b) // Ordinary retry.
    let reopenedDefaults = try #require(UserDefaults(suiteName: suite))
    #expect(ASCWebLoginStoreIdentity.current(in: reopenedDefaults) == b)
    let cleanupB = ASCWebLoginStoreIdentity.rotate(in: defaults)
    let c = ASCWebLoginStoreIdentity.current(in: defaults)
    #expect(cleanupB == b)
    #expect(c != b && c != cleanupA)
    // Delayed cleanup targets are immutable OLD IDs, never the current store.
    #expect(![cleanupA, cleanupB].contains(c))
}

@MainActor private final class LoginViewState {
    var loading = true
    var problem: String?
    var validation: String?
    var captures = 0

    func coordinator(timeout: Duration) -> ASCWebView.Coordinator {
        let view = ASCWebView(
            isLoading: Binding(get: { self.loading }, set: { self.loading = $0 }),
            loadProblem: Binding(get: { self.problem }, set: { self.problem = $0 }),
            validationMessage: Binding(get: { self.validation }, set: { self.validation = $0 }),
            control: ASCWebLoginControl(), onSessionCaptured: { _ in self.captures += 1 })
        let coordinator = ASCWebView.Coordinator(parent: view)
        coordinator.navigationTimeout = timeout
        return coordinator
    }
}

@MainActor @Test func webLoginInitialLoadWithoutAnyWebKitCallbackStopsLoading() async throws {
    let state = LoginViewState()
    let coordinator = state.coordinator(timeout: .milliseconds(10))
    coordinator.beginNavigation(nil) // No didStart, didFinish or didFail arrives.
    try await Task.sleep(for: .milliseconds(100))
    #expect(!state.loading)
    #expect(state.problem != nil)
    #expect(state.captures == 0)
    coordinator.cancel()
}

@MainActor @Test func webLoginClosingCancelsDeadlineAndPreventsLateUIChanges() async throws {
    let state = LoginViewState()
    let coordinator = state.coordinator(timeout: .milliseconds(10))
    coordinator.beginNavigation(nil)
    coordinator.cancel()
    state.loading = false
    try await Task.sleep(for: .milliseconds(100))
    #expect(!state.loading && state.problem == nil && state.captures == 0)
    coordinator.beginNavigation(nil)
    #expect(!state.loading)
}
