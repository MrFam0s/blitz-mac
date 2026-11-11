import Foundation
import Testing
import BlitzMCPCommon

struct BlitzReleaseCLITests {
    @Test func encodesUntrustedArgumentsAsData() throws {
        let call = try BlitzReleaseCLI.parse(["release", "prepare", "--request", "-"])
        let source: [String: Any] = ["appId": "123", "name": "$(touch /tmp/wrong); `x`\nKontaktimport"]
        let text = try BlitzReleaseCLI.request(call, data: JSONSerialization.data(withJSONObject: source), id: "test")
        let request = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["name"] as? String == "release_prepare")
        #expect((params["arguments"] as? [String: String]) == source as? [String: String])
    }

    @Test func rejectsUnknownCommandsAndNonobjectInput() throws {
        #expect(throws: BlitzReleaseCLI.CLIError.self) { try BlitzReleaseCLI.parse(["release", "delete", "--request", "-"]) }
        let call = try BlitzReleaseCLI.parse(["release", "status", "--request", "state.json"])
        #expect(throws: BlitzReleaseCLI.CLIError.self) { try BlitzReleaseCLI.request(call, data: Data("[]".utf8), id: "x") }
        #expect(throws: BlitzReleaseCLI.CLIError.self) { try BlitzReleaseCLI.request(call, data: Data(repeating: 32, count: 1_048_577), id: "x") }
    }

    @Test func rejectsWrongReplyAndPropagatesErrors() throws {
        #expect(throws: BlitzReleaseCLI.CLIError.self) {
            try BlitzReleaseCLI.output(response: #"{"jsonrpc":"2.0","id":"other","result":{}}"#, id: "test")
        }
        let output = try BlitzReleaseCLI.output(response: #"{"jsonrpc":"2.0","id":"test","result":{"content":[{"type":"text","text":"Error: target changed"}]}}"#, id: "test")
        #expect(output.failed)
        let protocolError = try BlitzReleaseCLI.output(response: #"{"jsonrpc":"2.0","id":"test","error":{"code":-32000,"message":"unknown outcome"}}"#, id: "test")
        #expect(protocolError.failed)
        for response in [#"{"jsonrpc":"2.0","id":"test","result":{}}"#,
                         #"{"jsonrpc":"2.0","id":"test","result":{"content":[{"type":"text","text":"Success"}]}}"#] {
            #expect(throws: BlitzReleaseCLI.CLIError.self) {
                try BlitzReleaseCLI.output(response: response, id: "test", tool: "release_submit")
            }
        }
    }

    @Test func unwrapsSuccessfulOperationWithoutReinterpretingItsStatus() throws {
        let output = try BlitzReleaseCLI.output(response: #"{"jsonrpc":"2.0","id":"test","result":{"content":[{"type":"text","text":"{\"operationId\":\"one\",\"stage\":\"blocked\"}"}]}}"#, id: "test")
        #expect(!output.failed)
        let record = try #require(JSONSerialization.jsonObject(with: Data(output.json.utf8)) as? [String: String])
        #expect(record["operationId"] == "one")
        #expect(record["stage"] == "blocked")
    }

    @Test func submitAndValidateExitUnsuccessfullyWhilePendingOrBlocked() throws {
        let response = #"{"jsonrpc":"2.0","id":"test","result":{"content":[{"type":"text","text":"{\"operationId\":\"one\",\"state\":\"submissionPending\",\"validation\":{\"ready\":false}}"}]}}"#
        #expect(try BlitzReleaseCLI.output(response: response, id: "test", tool: "release_submit").failed)
        #expect(try BlitzReleaseCLI.output(response: response, id: "test", tool: "release_validate").failed)
        #expect(try !BlitzReleaseCLI.output(response: response, id: "test", tool: "release_status").failed)
    }
}
