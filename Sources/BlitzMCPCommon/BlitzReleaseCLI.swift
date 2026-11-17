import Foundation

/// The CLI is a transport adapter. All release decisions remain in the app's
/// shared MCP backend; neither shell interpolation nor a second ASC stack is used.
public enum BlitzReleaseCLI {
    public static let help = """
    Blitz Neo release CLI

    Usage: blitz-macos-mcp release <command> --request <JSON-file|->
           blitz-macos-mcp release --help

    Commands:
      targets   List this explicitly named project's configured release targets.
      context   Read the explicitly requested project's current MCP target.
      prepare   Record an exact app/build and selected product versions; no Apple writes.
      prepare-resubmission  Plan corrections and resubmission of the same rejected review.
      validate  Refresh readiness and the prepared content fingerprint.
      status    Reconcile a saved operation with Apple; no Apple writes.
      submit    Submit only a validated, unchanged operation with its digest.

    Request files contain the same arguments as get_release_context or
    release_<command> in the MCP tool schema. Use '-' to read JSON from stdin.
    Blitz Neo must be running. Output is JSON. Authentication is shared with Blitz;
    never put credentials in request files. A timeout does not authorize a retry:
    use status with the saved operationId to reconcile the result first.

    A status result can expose resumableSubmissionId for a uniquely verified
    existing, unsubmitted draft. To continue that same authorized release, pass
    it as resumeSubmissionId to submit with the unchanged operationId, accountKey,
    confirmationDigest and confirm=true. This rechecks all release guards and
    submits only that existing draft. It never creates another draft. If the final
    submit has an uncertain outcome, only status is allowed; do not replay it.
    Legacy records without write phases additionally report
    requiresLegacyRecoveryConfirmation. Continue them with
    confirmLegacyDraftRecovery=true only when documented evidence proves that
    the previous run stopped before its final submit. The draft state alone
    cannot prove this. No new user approval is needed for unchanged already
    authorized scope, but an unknown old submit outcome must remain blocked.

    prepare-resubmission accepts the previous operationId, accountKey and exact
    submissionId. It reads Apple and creates a new operation/digest for the same
    app/build and complete item set. If rejected items remain, set
    resolveRejectedItems=true only after verifying and authorizing their corrections.
    This records the exact item IDs to resolve but performs no Apple writes.
    Validate and explicitly submit the new operation: only its planned rejected
    items are marked resolved, then that same review is resubmitted. Accepted items
    remain untouched. No replacement draft is created. A reply is not resubmission.
    Historical state=submitted is not a current queue status; inspect reviewOutcome,
    nextAction and submissionState. READY_FOR_REVIEW still needs the final send.
    After uncertainty, read status. Only an explicit resumableResubmissionId allows
    continuation of that same child using resumeSubmissionId and the same digest;
    an uncertain final send never permits replay.

    Preparation and validation do not authorize submission. Submission requires
    the user's instruction for the exact app, version, build and release mode.
    The underlying ASC CLI remains available for builds, uploads and metadata.
    Use targets with projectId first when a project supports several platforms.
    Prepare accepts releaseTargetId; it is required for multiple configured targets.
    Select exactly one target. An omitted ID never adopts the UI selection, and no
    command submits all platforms. Later commands use the saved operation's target.

    Joint app + In-App Purchase/subscription submission:
    Prepare optionally accepts reviewItems, an array of exact metadata versions:
      [{"type":"inAppPurchaseVersions","id":"IAP_VERSION_ID"},
       {"type":"subscriptionGroupVersions","id":"GROUP_VERSION_ID"},
       {"type":"subscriptionVersions","id":"SUBSCRIPTION_VERSION_ID"}]
    IDs are version resource IDs, not parent product IDs or productId strings.
    Include only authorized products and required new groups. At most 199 unique
    additional versions are allowed; the app version is added separately. Omitted
    or empty reviewItems keeps app-only behavior. Nothing is auto-selected.
    Preparation binds this exact set, product metadata and review media into the
    immutable operation. Later commands cannot change the set. After a pre-submit
    interruption, explicit continuation may add only missing saved items to that
    same owned draft. Unknown final submit outcomes still permit only status.
    """

    public struct Invocation {
        public let tool: String
        public let requestPath: String
    }

    public enum CLIError: LocalizedError {
        case usage, invalidRequest, oversizedRequest, invalidResponse
        public var errorDescription: String? {
            switch self {
            case .usage: return "Invalid release command. Use release --help."
            case .invalidRequest: return "Request must be one JSON object containing tool arguments."
            case .oversizedRequest: return "Request exceeds the 1 MiB limit."
            case .invalidResponse: return "Invalid or mismatched reply; reconcile the operation with release status before retrying."
            }
        }
    }

    public static func parse(_ arguments: [String]) throws -> Invocation {
        let commands = ["targets": "get_release_targets", "context": "get_release_context", "prepare": "release_prepare",
                        "prepare-resubmission": "release_prepare_resubmission",
                        "validate": "release_validate", "status": "release_status", "submit": "release_submit"]
        guard arguments.count == 4, arguments[0] == "release",
              let tool = commands[arguments[1]], arguments[2] == "--request",
              !arguments[3].isEmpty else { throw CLIError.usage }
        return Invocation(tool: tool, requestPath: arguments[3])
    }

    public static func request(_ invocation: Invocation, data: Data, id: String) throws -> String {
        guard data.count <= 1_048_576 else { throw CLIError.oversizedRequest }
        guard let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.invalidRequest
        }
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                    "params": ["name": invocation.tool, "arguments": arguments]]
        return String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
    }

    public static func output(response: String, id: String, tool: String? = nil) throws -> (json: String, failed: Bool) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
              object["jsonrpc"] as? String == "2.0", object["id"] as? String == id else {
            throw CLIError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] { return (try encode(["error": error]), true) }
        guard let result = object["result"] as? [String: Any] else { throw CLIError.invalidResponse }
        let contents = result["content"] as? [[String: Any]] ?? []
        let messages = contents.compactMap { $0["text"] as? String }
        let failed = result["isError"] as? Bool == true || messages.contains { $0.hasPrefix("Error:") }
        if !failed, messages.count == 1,
           let record = try? JSONSerialization.jsonObject(with: Data(messages[0].utf8)) as? [String: Any] {
            let currentSubmission = record["submissionState"] as? String
            let queueConfirmed = ["WAITING_FOR_REVIEW", "IN_REVIEW", "COMPLETING", "COMPLETE"].contains(currentSubmission ?? "")
            let versionConfirmed = ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE",
                                    "PROCESSING_FOR_APP_STORE", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "ACCEPTED"]
                .contains(record["appleState"] as? String ?? "")
            let currentConfirmed = queueConfirmed && versionConfirmed &&
                (record["reviewOutcome"] == nil || record["reviewOutcome"] as? String == "submitted")
            let incomplete = (tool == "release_submit" && (record["state"] as? String != "submitted" || !currentConfirmed))
                || (tool == "release_validate" && (record["validation"] as? [String: Any])?["ready"] as? Bool != true)
            return (try encode(record), incomplete)
        }
        if failed { return (try encode(result), true) }
        throw CLIError.invalidResponse
    }

    private static func encode(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}
