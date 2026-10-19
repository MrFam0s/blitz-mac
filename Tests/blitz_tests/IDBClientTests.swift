import Foundation
import Testing
@testable import Blitz

struct IDBClientTests {
    @Test func closedSessionRejectsLateInputWithoutStartingHelpers() async throws {
        let client = IDBClient()
        await client.shutdown()
        do {
            try await client.tap(udid: UUID().uuidString, x: 1, y: 1)
            Issue.record("A late tap must not restart a closed session")
        } catch is CancellationError {}
    }

    @Test func helperEnvironmentExcludesCredentialsAndInjection() async throws {
        let source = ["HOME": "/tmp/idb-test", "PATH": "/usr/bin:/bin",
                      "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                      "OPENAI_API_KEY": "test-only", "ASC_PRIVATE_KEY": "test-only",
                      "IDB_SECRET": "test-only", "PYTHONPATH": "/tmp/injection",
                      "DYLD_INSERT_LIBRARIES": "/tmp/injection.dylib"]
        let safe = IDBClient.helperEnvironment(source)
        #expect(Set(safe.keys) == ["HOME", "PATH", "DEVELOPER_DIR"])
        // Verify the process boundary really replaces the parent environment.
        let output = try await ProcessRunner.run("/usr/bin/env", environment: safe,
                                                 inheritEnvironment: false)
        #expect(Set(output.split(separator: "\n").map(String.init)) ==
                Set(safe.map { "\($0.key)=\($0.value)" }))
    }
}
