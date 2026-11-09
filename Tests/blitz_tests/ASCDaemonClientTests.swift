import Foundation
import Testing
@testable import Blitz

@Test func testSequencedPipeBufferReassemblesOutOfOrderChunks() {
    var buffer = SequencedPipeBuffer()

    let delayed = buffer.append(Data("\"result\":{\"statusCode\":200}}\n".utf8), sequence: 1)
    #expect(delayed.isEmpty)

    let lines = buffer.append(Data("{\"id\":\"ascd-39\",".utf8), sequence: 0)
    #expect(lines.count == 1)
    #expect(String(data: lines[0], encoding: .utf8) == "{\"id\":\"ascd-39\",\"result\":{\"statusCode\":200}}")
}

@Test func testSequencedPipeBufferFlushesTrailingChunkAtEOF() {
    var buffer = SequencedPipeBuffer()

    let partial = buffer.append(Data("partial stderr".utf8), sequence: 0)
    #expect(partial.isEmpty)

    let flushed = buffer.append(Data(), sequence: 1)
    #expect(flushed.count == 1)
    #expect(String(data: flushed[0], encoding: .utf8) == "partial stderr")
}

@Test func daemonCredentialEnvironmentKeepsSelectedAccountForCLIUploads() async throws {
    let inherited = [
        "PATH": "/usr/bin:/bin",
        "ASC_KEY_ID": "OTHER-KEY",
        "ASC_ISSUER_ID": "OTHER-ISSUER",
        "ASC_PRIVATE_KEY": "OTHER-PEM",
        "ASC_PRIVATE_KEY_PATH": "/tmp/other-key.p8",
        "ASC_PRIVATE_KEY_B64": "OTHER-BASE64",
        "ASC_BEARER_TOKEN": "OTHER-ACCOUNT-TOKEN",
        "ASC_KEY_TYPE": "enterprise",
        "ASC_BYPASS_KEYCHAIN": "0",
        "ASC_TELEMETRY_DISABLED": "1",
        "ASC_WEB_SESSION_CACHE_DIR": "/tmp/web-cache-fixture",
    ]
    let credentials = ASCCredentials(
        issuerId: "SELECTED-ISSUER", keyId: "SELECTED-KEY", privateKey: "SELECTED-PEM"
    )
    let environment = ASCDaemonClient.credentialEnvironment(
        credentials: credentials, inherited: inherited
    )
    #expect(environment["ASC_BEARER_TOKEN"] == nil)
    #expect(environment["ASC_KEY_TYPE"] == nil)
    #expect(environment["ASC_KEY_ID"] == credentials.keyId)
    #expect(environment["ASC_ISSUER_ID"] == credentials.issuerId)
    #expect(environment["ASC_PRIVATE_KEY"] == credentials.privateKey)
    #expect(environment["ASC_PRIVATE_KEY_PATH"] == nil)
    #expect(environment["ASC_PRIVATE_KEY_B64"] == nil)
    #expect(environment["ASC_BYPASS_KEYCHAIN"] == "1")
    #expect(environment["PATH"] == inherited["PATH"])
    #expect(environment["ASC_TELEMETRY_DISABLED"] == "1")
    #expect(environment["ASC_WEB_SESSION_CACHE_DIR"] == inherited["ASC_WEB_SESSION_CACHE_DIR"])

    // Exercise the process boundary with fictional credentials only. The daemon
    // launches cli.exec with this environment, while direct terminal CLI keeps
    // the caller's original token and key-type settings.
    let output = try await ProcessRunner.run(
        "/usr/bin/env", environment: environment, inheritEnvironment: false
    )
    #expect(Set(output.split(separator: "\n").map(String.init)) ==
            Set(environment.map { "\($0.key)=\($0.value)" }))
    #expect(inherited["ASC_BEARER_TOKEN"] == "OTHER-ACCOUNT-TOKEN")
    #expect(inherited["ASC_KEY_TYPE"] == "enterprise")
}
