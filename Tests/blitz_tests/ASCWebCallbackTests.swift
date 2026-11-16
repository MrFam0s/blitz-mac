import Foundation
import Testing
@testable import Blitz

@MainActor @Test func webCallbackTimesOutWhenWebKitNeverCallsBack() async throws {
    let clock = ContinuousClock()
    let startedAt = clock.now
    var callback: (@MainActor (Result<String, Error>) -> Void)?
    await #expect(throws: ASCWebCallbackError.timedOut) {
        let _: String = try await ASCWebCallback.wait(timeout: 0.02) { callback = $0 }
    }
    #expect(startedAt.duration(to: clock.now) < .seconds(2))
    // WebKit may eventually deliver success or failure after the deadline.
    // Neither may resume the continuation again or revive the timed-out call.
    let lateCallback = try #require(callback)
    lateCallback(.success("late"))
    lateCallback(.failure(URLError(.networkConnectionLost)))
}

@MainActor @Test func webCallbackCancellationDoesNotWaitForCallbackOrDeadline() async throws {
    var callback: (@MainActor (Result<String, Error>) -> Void)?
    let task = Task {
        try await ASCWebCallback.wait(timeout: 60) { callback = $0 }
    }
    while callback == nil { await Task.yield() }
    let startedAt = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(startedAt.duration(to: .now) < .seconds(2))
    let lateCallback = try #require(callback)
    lateCallback(.success("late"))
    lateCallback(.success("duplicate"))
}

@MainActor @Test func webCallbackAlreadyCancelledTaskDoesNotStartBrowserWork() async {
    var didStart = false
    let task = Task {
        let _: Void = try await ASCWebCallback.wait(timeout: 60) { _ in didStart = true }
    }
    // This main-actor task cannot start before the test first suspends below.
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!didStart)
}

@MainActor @Test func webCallbackCancellationAfterSynchronousSuccessStillThrows() async {
    let task = Task {
        let result: String = try await ASCWebCallback.wait(timeout: 1) { completion in
            completion(.success("completed while cancellation was arriving"))
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return result
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@MainActor @Test func webCallbackSynchronousSuccessIgnoresDuplicateCompletionAndTimer() async throws {
    var callback: (@MainActor (Result<Any, Error>) -> Void)?
    let result: Any = try await ASCWebCallback.wait(timeout: 0.01) { completion in
        callback = completion
        completion(.success(["status": 200]))
        completion(.failure(URLError(.cannotConnectToHost)))
    }
    #expect((result as? [String: Int])?["status"] == 200)
    try await Task.sleep(for: .milliseconds(30))
    callback?(.success("late"))
}

@MainActor @Test func webCallbackPreservesOriginalCallbackFailure() async {
    await #expect(throws: URLError(.notConnectedToInternet)) {
        let _: Void = try await ASCWebCallback.wait(timeout: 30) {
            $0(.failure(URLError(.notConnectedToInternet)))
        }
    }
}

@MainActor @Test func webCallbackSupportsCookiesAndVoidWithoutSendableCoercion() async throws {
    let cookie = try #require(HTTPCookie(properties: [
        .name: "fixture", .value: "synthetic", .domain: "example.invalid", .path: "/"
    ]))
    let cookies: [HTTPCookie] = try await ASCWebCallback.wait(timeout: 1) {
        $0(.success([cookie]))
    }
    #expect(cookies.count == 1)
    #expect(cookies.first?.name == "fixture")
    let _: Void = try await ASCWebCallback.wait(timeout: 1) { $0(.success(())) }
}

@MainActor @Test func webCallbackRejectsInvalidDeadlineWithoutStartingBrowserWork() async {
    for timeout in [0, -1, .infinity, .nan] {
        var didStart = false
        await #expect(throws: ASCWebCallbackError.timedOut) {
            let _: Void = try await ASCWebCallback.wait(timeout: timeout) { _ in didStart = true }
        }
        #expect(!didStart)
    }
}
