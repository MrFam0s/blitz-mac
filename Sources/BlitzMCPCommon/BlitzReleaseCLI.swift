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
      prepare   Record an exact app/version/already-attached build; no Apple writes.
      validate  Refresh readiness and the prepared content fingerprint.
      status    Reconcile a saved operation with Apple; no Apple writes.
      submit    Submit only a validated, unchanged operation with its digest.

    Request files contain the same arguments as get_release_context or
    release_<command> in the MCP tool schema. Use '-' to read JSON from stdin.
    Blitz Neo must be running. Output is JSON. Authentication is shared with Blitz;
    never put credentials in request files. A timeout does not authorize a retry:
    use status with the saved operationId to reconcile the result first.

    Preparation and validation do not authorize submission. Submission requires
    the user's instruction for the exact app, version, build and release mode.
    The underlying ASC CLI remains available for builds, uploads and metadata.
    Use targets with projectId first when a project supports several platforms.
    Prepare accepts releaseTargetId; it is required for multiple configured targets.
    Select exactly one target. An omitted ID never adopts the UI selection, and no
    command submits all platforms. Later commands use the saved operation's target.
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
            let incomplete = (tool == "release_submit" && record["state"] as? String != "submitted")
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
