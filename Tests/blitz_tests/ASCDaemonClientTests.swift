import Darwin
import Foundation
import Testing
@testable import Blitz

private func isBrokenPipe(_ error: Error) -> Bool {
    let cocoaError = error as NSError
    let cause = (cocoaError.userInfo[NSUnderlyingErrorKey] as? NSError) ?? cocoaError
    return cause.domain == NSPOSIXErrorDomain && cause.code == Int(EPIPE)
}

@Test func subprocessInputReportsBrokenPipeAfterReaderCloses() throws {
    let pipe = try makeSubprocessInputPipe()
    let writer = pipe.fileHandleForWriting
    try #require(fcntl(writer.fileDescriptor, F_GETNOSIGPIPE) == 1)
    try pipe.fileHandleForReading.close()
    do {
        try writer.write(contentsOf: Data([1]))
        Issue.record("Writing to a pipe with no readers must fail")
    } catch {
        #expect(isBrokenPipe(error))
    }
}

private func makeDaemonFixture(in directory: URL, script: String) throws -> ASCDaemonClient {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let helper = directory.appendingPathComponent("helper.sh")
    try script.write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let credentials = ASCCredentials(issuerId: "fixture", keyId: "fixture", privateKey: "fixture")
    return ASCDaemonClient(credentials: credentials, executableURL: helper)
}

@Test func daemonBrokenPipeFailsPendingRequestsWithoutReplayingThem() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = try makeDaemonFixture(in: directory, script: #"""
    #!/bin/sh
    dir=$(/usr/bin/dirname "$0")
    IFS= read -r request || exit 1
    printf '%s\n' "$request" >> "$dir/received"
    if [ ! -e "$dir/closed" ]; then
        exec 0<&-
        touch "$dir/closed"
    else
        id=$(printf '%s' "$request" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\1/')
        printf '{"id":"%s","result":{"exitCode":0,"stdout":"recovered"}}\n' "$id"
    fi
    exec /bin/sleep 10
    """#)
    let pending = Task { try await client.cliExec(args: ["already-sent"], responseTimeoutSeconds: 8) }
    let closed = directory.appendingPathComponent("closed")
    for _ in 0..<250 {
        if FileManager.default.fileExists(atPath: closed.path) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(FileManager.default.fileExists(atPath: closed.path))
    do {
        _ = try await client.cliExec(args: ["broken-write"], responseTimeoutSeconds: 3)
        Issue.record("The helper had already closed stdin")
    } catch {
        #expect(isBrokenPipe(error))
    }
    do {
        _ = try await pending.value
        Issue.record("The original request received no response")
    } catch {
        #expect(isBrokenPipe(error))
    }
    let next = try await client.cliExec(args: ["new-request"], responseTimeoutSeconds: 3)
    #expect(next.stdout == "recovered")
    let received = try String(contentsOf: directory.appendingPathComponent("received"), encoding: .utf8)
    let arguments = try received.split(separator: "\n").map { line in
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        return (object?["params"] as? [String: Any])?["args"] as? [String]
    }
    #expect(arguments == [["already-sent"], ["new-request"]])
}

@Test func daemonSessionRequestStaysWithTheHelperThatOpenedItsSession() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = try makeDaemonFixture(in: directory, script: #"""
    #!/bin/sh
    dir=$(/usr/bin/dirname "$0")
    read_request() {
        IFS= read -r request || exit 2
        printf '%s\n' "$request" >> "$dir/received"
        id=$(printf '%s' "$request" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\1/')
    }
    read_request
    first=false
    if [ ! -e "$dir/closed" ]; then
        first=true
        touch "$dir/closed"
        exec 0<&-
    fi
    printf '{"id":"%s","result":{"session":{"usesInMemoryKey":true}}}\n' "$id"
    if [ "$first" = false ]; then
        read_request
        printf '{"id":"%s","result":{"statusCode":200,"body":"ok"}}\n' "$id"
    fi
    exec /bin/sleep 10
    """#)
    do {
        _ = try await client.request(method: "PATCH", path: "/fixture")
        Issue.record("The helper closed stdin during session.open")
    } catch {
        #expect(isBrokenPipe(error))
    }
    let next = try await client.request(method: "GET", path: "/fixture")
    #expect(next.statusCode == 200)
    let received = try String(contentsOf: directory.appendingPathComponent("received"), encoding: .utf8)
    let requests = try received.split(separator: "\n").map { line in
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    #expect(requests.compactMap { $0["method"] as? String } == ["session.open", "session.open", "session.request"])
    let httpRequests = requests.compactMap { ($0["params"] as? [String: Any])?["method"] as? String }
    #expect(httpRequests == ["GET"])
}

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
        "ASC_BEARER_TOKEN_COMMAND": "external-token-command",
        "ASC_WEB_BROKER_URL": "https://other-account.invalid",
        "ASC_WEB_BROKER_TOKEN": "OTHER-BROKER-TOKEN",
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
    #expect(environment["ASC_BEARER_TOKEN_COMMAND"] == nil)
    #expect(environment["ASC_WEB_BROKER_URL"] == nil)
    #expect(environment["ASC_WEB_BROKER_TOKEN"] == nil)
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
    #expect(inherited["ASC_BEARER_TOKEN_COMMAND"] == "external-token-command")
    #expect(inherited["ASC_WEB_BROKER_URL"] == "https://other-account.invalid")
    #expect(inherited["ASC_WEB_BROKER_TOKEN"] == "OTHER-BROKER-TOKEN")
}
