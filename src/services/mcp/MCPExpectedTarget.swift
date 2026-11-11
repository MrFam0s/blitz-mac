import Foundation

/// A caller names the intended Store target. The current UI selection is only
/// checked against it; it is never used to repair or silently retarget a request.
struct MCPExpectedTarget: Equatable, Sendable {
    let projectId: String
    let projectPath: String
    let appId: String
    let bundleId: String
    let platform: String
    let accountKey: String
    let versionId: String?
    let releaseTargetId: String?

    static let boundTools: Set<String> = [
        "asc_fill_form", "asc_select_version", "asc_create_version", "asc_open_submit_preview",
        "app_information_switch_localization", "store_listing_switch_localization",
        "screenshots_switch_localization", "screenshots_put_track_slot", "screenshots_remove_track_slot",
        "screenshots_reorder_track", "screenshots_save", "asc_create_iap", "asc_create_subscription",
        "asc_set_app_price", "app_store_setup_signing", "app_store_build", "app_store_upload",
    ]

    static func requiresBinding(tool: String, arguments: [String: Any]) -> Bool {
        // The pre-Store identity form has its own confirmed operation protocol.
        if tool == "asc_fill_form", arguments["tab"] as? String == "settings.bundleId" { return false }
        return boundTools.contains(tool)
    }

    static var schema: [String: Any] {
        let strings = ["projectId", "projectPath", "appId", "bundleId", "platform", "accountKey"]
        var properties = Dictionary(uniqueKeysWithValues: strings.map { ($0, ["type": "string", "minLength": 1] as [String: Any]) })
        properties["versionId"] = ["type": ["string", "null"], "description": "Exact selected version ID, or explicit null when none is selected."]
        properties["releaseTargetId"] = ["type": "string", "description": "Exact configured release target. Required for projects with multiple targets; copy from get_release_context."]
        return ["type": "object", "additionalProperties": false, "properties": properties,
                "required": strings + ["versionId"],
                "description": "Copy expectedTarget from get_release_context for the intended project/app. Re-read after changing version; never substitute the current selection implicitly."]
    }

    init(json: [String: Any]) throws {
        func string(_ key: String) throws -> String {
            guard let value = json[key] as? String, !value.isEmpty,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw MCPBoundRequestError.invalidTarget
            }
            return value
        }
        projectId = try string("projectId")
        projectPath = try string("projectPath")
        appId = try string("appId")
        bundleId = try string("bundleId")
        platform = try string("platform")
        accountKey = try string("accountKey")
        releaseTargetId = try json.keys.contains("releaseTargetId") ? string("releaseTargetId") : nil
        guard projectPath.hasPrefix("/"), ProjectPlatform(rawValue: platform) != nil,
              json.keys.contains("versionId") else { throw MCPBoundRequestError.invalidTarget }
        if json["versionId"] is NSNull { versionId = nil }
        else { versionId = try string("versionId") }
    }

    init(captured: MCPReleaseRequestTarget) throws {
        guard let projectId = captured.projectID, let projectPath = captured.projectPath,
              let appId = captured.appID, let bundleId = captured.bundleID,
              let platform = captured.platform, let accountKey = captured.accountKey else {
            throw MCPBoundRequestError.invalidTarget
        }
        var json: [String: Any] = ["projectId": projectId, "projectPath": projectPath,
            "appId": appId, "bundleId": bundleId,
            "platform": platform, "accountKey": accountKey,
            "versionId": captured.selectedVersionID.map { $0 as Any } ?? NSNull()]
        if let releaseTargetID = captured.releaseTargetID { json["releaseTargetId"] = releaseTargetID }
        try self.init(json: json)
    }

    var json: [String: Any] {
        var value: [String: Any] = ["projectId": projectId, "projectPath": projectPath, "appId": appId, "bundleId": bundleId,
         "platform": platform, "accountKey": accountKey, "versionId": versionId.map { $0 as Any } ?? NSNull()]
        if let releaseTargetId { value["releaseTargetId"] = releaseTargetId }
        return value
    }

    func matches(_ current: MCPReleaseRequestTarget) -> Bool {
        projectId == current.projectID && projectPath == current.projectPath && appId == current.appID
            && bundleId == current.bundleID && platform == current.platform && accountKey == current.accountKey
            && versionId == current.selectedVersionID
            && (releaseTargetId == current.releaseTargetID
                || (releaseTargetId == nil && current.releaseTargetCount == 1 && current.releaseTargetID == "legacy"))
    }
}

enum MCPBoundRequestError: LocalizedError {
    case invalidTarget, targetChanged, busy, expired
    var errorDescription: String? {
        switch self {
        case .invalidTarget: "expectedTarget is required. Call get_release_context with the intended projectId and appId, then pass its complete expectedTarget (including versionId)."
        case .targetChanged: "The intended project, app, account or version no longer matches. No further writes are allowed. Recheck the original target before continuing."
        case .busy: "Another Blitz operation owns the UI target. Wait for it to finish; do not switch projects or start a competing mutation."
        case .expired: "This MCP operation has finished; delayed work cannot perform additional writes."
        }
    }
}

/// Inherited by child Tasks, including existing manager tasks. Every transport
/// write checks this scope, so a batch cannot acquire a different UI target later.
final class MCPMutationScope: @unchecked Sendable {
    @TaskLocal static var current: MCPMutationScope?
    private let lock = NSLock()
    private var active = true
    private let validate: @MainActor @Sendable () throws -> Void

    init(validate: @escaping @MainActor @Sendable () throws -> Void) { self.validate = validate }
    func finish() { lock.lock(); active = false; lock.unlock() }
    private func checkActive() throws {
        lock.lock(); let valid = active; lock.unlock()
        guard valid else { throw MCPBoundRequestError.expired }
    }
    @MainActor func check() throws {
        try checkActive()
        try Task.checkCancellation()
        try validate()
    }
    @MainActor static func checkCurrent() throws { try current?.check() }
    static func checkBeforeWrite() async throws {
        guard let current else { return }
        try await current.check()
    }
}
