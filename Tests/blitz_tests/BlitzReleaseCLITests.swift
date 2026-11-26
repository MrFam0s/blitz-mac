import Foundation
import Testing
import BlitzMCPCommon

struct BlitzReleaseCLITests {
    @Test func jointReleaseRequestAndResultPreserveExactVersionSelection() throws {
        let invocation = try BlitzReleaseCLI.parse(["release", "prepare", "--request", "-"])
        let selected: [[String: String]] = [
            ["type": "subscriptionGroupVersions", "id": "group-version"],
            ["type": "subscriptionVersions", "id": "subscription-version"],
            ["type": "inAppPurchaseVersions", "id": "purchase-version"]]
        let data = try JSONSerialization.data(withJSONObject: ["appId": "app", "reviewItems": selected])
        let payload = try BlitzReleaseCLI.request(invocation, data: data, id: "joint")
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let args = try #require((envelope["params"] as? [String: Any])?["arguments"] as? [String: Any])
        #expect(args["reviewItems"] as? [[String: String]] == selected)
        let record: [String: Any] = ["operationId": "joint", "target": ["reviewItems": selected], "state": "prepared"]
        let response = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "joint", "result": ["content": [
            ["type": "text", "text": String(decoding: JSONSerialization.data(withJSONObject: record), as: UTF8.self)]]]])
        let result = try BlitzReleaseCLI.output(response: String(decoding: response, as: UTF8.self), id: "joint", tool: "release_prepare")
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
        #expect(!result.failed)
        #expect((decoded["target"] as? [String: Any])?["reviewItems"] as? [[String: String]] == selected)
    }

    @Test func draftRefreshForwardsTheExistingConfirmationWithoutSubmitting() throws {
        let invocation = try BlitzReleaseCLI.parse(["release", "prepare-draft-refresh", "--request", "-"])
        #expect(invocation.tool == "release_prepare_draft_refresh")
        let values = ["operationId": "operation", "accountKey": "account", "submissionId": "draft", "confirmationDigest": "previous"]
        let request = try BlitzReleaseCLI.request(invocation, data: JSONEncoder().encode(values), id: "id")
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        let params = try #require(parsed["params"] as? [String: Any])
        #expect(params["name"] as? String == invocation.tool)
        #expect(params["arguments"] as? [String: String] == values)
    }

    @Test func draftContinuationKeepsExactSavedOperationAndDoesNotClaimSubmission() throws {
        let invocation = try BlitzReleaseCLI.parse(["release", "submit", "--request", "-"])
        let request: [String: Any] = ["operationId": "saved-operation", "accountKey": "issuer:key",
            "confirmationDigest": "unchanged", "confirm": true, "resumeSubmissionId": "existing-draft",
            "confirmLegacyDraftRecovery": true]
        let payload = try BlitzReleaseCLI.request(invocation, data: JSONSerialization.data(withJSONObject: request), id: "id")
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let arguments = try #require((parsed["params"] as? [String: Any])?["arguments"] as? [String: Any])
        #expect(arguments["operationId"] as? String == "saved-operation")
        #expect(arguments["resumeSubmissionId"] as? String == "existing-draft")
        #expect(arguments["confirmationDigest"] as? String == "unchanged")
        #expect(arguments["confirmLegacyDraftRecovery"] as? Bool == true)
        let response = #"{"jsonrpc":"2.0","id":"id","result":{"content":[{"type":"text","text":"{\"operationId\":\"saved-operation\",\"state\":\"submissionPending\",\"resumableSubmissionId\":\"existing-draft\",\"appleState\":\"READY_FOR_REVIEW\"}"}]}}"#
        #expect(try BlitzReleaseCLI.output(response: response, id: "id", tool: "release_submit").failed)
        #expect(try !BlitzReleaseCLI.output(response: response, id: "id", tool: "release_status").failed)
    }

    @Test func discoversTargetsAndPassesExplicitSelectionUnchanged() throws {
        let discovery = try BlitzReleaseCLI.parse(["release", "targets", "--request", "-"])
        #expect(discovery.tool == "get_release_targets")
        let prepare = try BlitzReleaseCLI.parse(["release", "prepare", "--request", "-"])
        let data = Data(#"{"projectId":"shared","releaseTargetId":"native-mac","appId":"123","platform":"MAC_OS"}"#.utf8)
        let payload = try BlitzReleaseCLI.request(prepare, data: data, id: "id")
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let args = try #require((parsed["params"] as? [String: Any])?["arguments"] as? [String: String])
        #expect(args["releaseTargetId"] == "native-mac")
        #expect(args["platform"] == "MAC_OS")
    }
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
    @Test func resubmissionPreparationUsesExplicitOldOperationAndHistoricalSubmittedIsNotSuccess() throws {
        let invocation = try BlitzReleaseCLI.parse(["release", "prepare-resubmission", "--request", "-"])
        #expect(invocation.tool == "release_prepare_resubmission")
        let data = Data(#"{"operationId":"old","accountKey":"issuer:key","submissionId":"review"}"#.utf8)
        let request = try BlitzReleaseCLI.request(invocation, data: data, id: "id")
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        let params = try #require(parsed["params"] as? [String: Any])
        #expect(params["name"] as? String == "release_prepare_resubmission")
        for state in ["UNRESOLVED_ISSUES", "READY_FOR_REVIEW"] {
            let record = ["state": "submitted", "submissionState": state, "appleState": "READY_FOR_REVIEW"]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
            let response = String(decoding: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "id",
                "result": ["content": [["type": "text", "text": text]]]]), as: UTF8.self)
            #expect(try BlitzReleaseCLI.output(response: response, id: "id", tool: "release_submit").failed)
            #expect(try !BlitzReleaseCLI.output(response: response, id: "id", tool: "release_status").failed)
        }
    }

    @Test func submitSuccessRequiresConsistentCurrentAppleEvidence() throws {
        for (record, success) in [
            (["state": "submitted"], false),
            (["state": "submitted", "submissionState": "COMPLETE", "appleState": "REJECTED"], false),
            (["state": "submitted", "submissionState": "WAITING_FOR_REVIEW", "appleState": "READY_FOR_REVIEW"], false),
            (["state": "submitted", "submissionState": "WAITING_FOR_REVIEW", "appleState": "WAITING_FOR_REVIEW", "reviewOutcome": "issuesUnresolved"], false),
            (["state": "submitted", "submissionState": "WAITING_FOR_REVIEW", "appleState": "WAITING_FOR_REVIEW", "reviewOutcome": "submitted"], true)
        ] {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
            let response = String(decoding: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "id",
                "result": ["content": [["type": "text", "text": text]]]]), as: UTF8.self)
            #expect(try BlitzReleaseCLI.output(response: response, id: "id", tool: "release_submit").failed == !success)
        }
    }

}
