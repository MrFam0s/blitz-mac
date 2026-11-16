// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

enum ASCWebCallbackError: Error, Equatable {
    case timedOut
}

/// Bounds WebKit's main-actor callback APIs even when the web process never
/// calls back. A task group cannot provide this guarantee: leaving its scope
/// would still wait for a non-cooperative callback child to finish.
@MainActor
enum ASCWebCallback {
    static func wait<Value>(
        timeout: TimeInterval,
        start: (@escaping @MainActor (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0 else { throw ASCWebCallbackError.timedOut }
        let pending = Pending<Value>()
        let value: Value = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                guard !Task.isCancelled else {
                    pending.finish(.failure(CancellationError()))
                    return
                }
                guard !pending.isFinished else { return }
                // Clamp before conversion so an unexpectedly large interval
                // cannot overflow UInt64. Normal browser deadlines are seconds.
                let seconds = min(timeout, TimeInterval(UInt64.max / 1_000_000_000))
                let nanoseconds = UInt64(seconds * 1_000_000_000)
                pending.timeoutTask = Task { @MainActor [weak pending] in
                    do { try await Task.sleep(nanoseconds: nanoseconds) }
                    catch { return }
                    pending?.finish(.failure(ASCWebCallbackError.timedOut))
                }
                start { result in pending.finish(result) }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
        // The cancellation handler must hop back to the main actor. A success
        // callback already queued there can therefore win the one-shot gate
        // after cancellation was requested; never return that value as success.
        try Task.checkCancellation()
        return value
    }

    @MainActor
    private final class Pending<Value> {
        private var continuation: CheckedContinuation<Value, Error>?
        private var earlyResult: Result<Value, Error>?
        private var isInstalled = false
        private(set) var isFinished = false
        var timeoutTask: Task<Void, Never>?

        deinit { timeoutTask?.cancel() }

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            precondition(!isInstalled)
            isInstalled = true
            if let result = earlyResult {
                earlyResult = nil
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
            }
        }

        func finish(_ result: Result<Value, Error>) {
            guard !isFinished else { return }
            isFinished = true
            timeoutTask?.cancel()
            timeoutTask = nil
            if let continuation {
                self.continuation = nil
                continuation.resume(with: result)
            } else {
                // Cancellation can win before the continuation is installed.
                earlyResult = result
            }
        }
    }
}
