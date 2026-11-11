import CryptoKit
import Foundation

enum ReleaseWorkflowAPIError: Error, LocalizedError {
    case httpStatus(Int), invalidResponse, validationUnavailable
    var errorDescription: String? {
        switch self {
        case .httpStatus(let status): return "Apple-Anfrage für den Release-Auftrag fehlgeschlagen (HTTP \(status))."
        case .invalidResponse: return "Apple lieferte keine vollständig zuordenbare Release-Antwort."
        case .validationUnavailable: return "Die vollständige ASC-Release-Prüfung konnte nicht verifiziert werden."
        }
    }
}

/// The app, MCP and one-shot CLI use the same authenticated helper. No shell,
/// global ASC defaults or current UI selection participate in these requests.
final class ReleaseWorkflowASCAdapter: ReleaseWorkflowAPI {
    typealias Request = (String, String, [String: String], Data?) async throws -> ASCDaemonClient.HTTPResponse
    typealias CLI = ([String]) async throws -> (exitCode: Int, stdout: String, stderr: String)
    let accountKey: String
    private let transport: Request
    private let cli: CLI
    private let loadBuild: (String) async throws -> ASCBuild
    private let validateContext: () async throws -> Void
    private let readinessReport: ((ReleaseWorkflowTarget) async throws -> ReleaseReadinessPayload)?

    init(credentials: ASCCredentials, validateContext: @escaping () async throws -> Void = {}) {
        accountKey = "\(credentials.issuerId):\(credentials.keyId)"
        let client = ASCDaemonClient(credentials: credentials)
        let service = AppStoreConnectService(credentials: credentials)
        transport = { try await client.request(method: $0, path: $1, headers: $2, body: $3) }
        cli = { try await service.cliExec(args: $0, responseTimeoutSeconds: 240) }
        loadBuild = { try await service.fetchBuild(id: $0) }
        readinessReport = { target in
            try await client.releaseReadiness(appID: target.appID, bundleID: target.bundleID,
                                              versionID: target.versionID, platform: target.platform)
        }
        self.validateContext = validateContext
    }

    /// All integration tests inject transports; no credentials or real Apple calls are needed.
    init(accountKey: String, transport: @escaping Request, cli: @escaping CLI,
         loadBuild: @escaping (String) async throws -> ASCBuild,
         validateContext: @escaping () async throws -> Void = {},
         readinessReport: ((ReleaseWorkflowTarget) async throws -> ReleaseReadinessPayload)? = nil) {
        self.accountKey = accountKey; self.transport = transport; self.cli = cli
        self.loadBuild = loadBuild; self.validateContext = validateContext
        self.readinessReport = readinessReport
    }

    func snapshot(_ target: ReleaseWorkflowTarget) async throws -> ReleaseWorkflowSnapshot {
        try target.validate()
        guard accountKey == target.accountKey else { throw ReleaseWorkflowError.accountChanged }
        let app = try await single("/v1/apps/\(target.appID)")
        guard app["id"] as? String == target.appID,
              let appAttributes = app["attributes"] as? [String: Any],
              appAttributes["bundleId"] as? String == target.bundleID else { throw ReleaseWorkflowError.identityChanged }
        let versions = try await all("/v1/apps/\(target.appID)/appStoreVersions")
        guard let version = versions.first(where: { $0["id"] as? String == target.versionID }),
              let attrs = version["attributes"] as? [String: Any],
              attrs["platform"] as? String == target.platform,
              let versionString = attrs["versionString"] as? String else { throw ReleaseWorkflowError.identityChanged }
        try await validateContext()
        let build = try await loadBuild(target.buildID)
        guard build.appId == target.appID, build.preReleaseVersion?.attributes.version == versionString,
              build.preReleaseVersion?.attributes.platform == target.platform else { throw ReleaseWorkflowError.identityChanged }
        let attached = try await optionalSingle("/v1/appStoreVersions/\(target.versionID)/build")
        let state = (attrs["appVersionState"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (attrs["appStoreState"] as? String ?? "UNKNOWN")
        var protected: [String: Any] = ["app": appAttributes,
            "version": attrs.filter { !["appStoreState", "appVersionState", "releaseType", "createdDate"].contains($0.key) }]

        let localizations = try await all("/v1/appStoreVersions/\(target.versionID)/appStoreVersionLocalizations")
        var localized: [[String: Any]] = []
        for localization in localizations.sorted(by: Self.resourceOrder) {
            let id = try Self.id(localization)
            var item = Self.semantic(localization)
            var sets: [[String: Any]] = []
            for set in try await all("/v1/appStoreVersionLocalizations/\(id)/appScreenshotSets").sorted(by: Self.resourceOrder) {
                var value = Self.semantic(set)
                value["screenshots"] = try await all("/v1/appScreenshotSets/\(Self.id(set))/appScreenshots").map(Self.semantic)
                sets.append(value) // Preserve screenshot order within each device set.
            }
            item["screenshots"] = sets
            var previews: [[String: Any]] = []
            for set in try await all("/v1/appStoreVersionLocalizations/\(id)/appPreviewSets").sorted(by: Self.resourceOrder) {
                var value = Self.semantic(set)
                value["previews"] = try await all("/v1/appPreviewSets/\(Self.id(set))/appPreviews").map(Self.semantic)
                previews.append(value)
            }
            item["previews"] = previews
            localized.append(item)
        }
        protected["localizations"] = localized
        var infos: [[String: Any]] = []
        for info in try await all("/v1/apps/\(target.appID)/appInfos", query: ["include":
            "primaryCategory,primarySubcategoryOne,primarySubcategoryTwo,secondaryCategory,secondarySubcategoryOne,secondarySubcategoryTwo"])
            .sorted(by: Self.resourceOrder) {
            let id = try Self.id(info)
            var value = Self.semantic(info)
            if var a = value["attributes"] as? [String: Any] {
                a.removeValue(forKey: "appStoreState"); a.removeValue(forKey: "appVersionState")
                value["attributes"] = a
            }
            value["localizations"] = try await all("/v1/appInfos/\(id)/appInfoLocalizations").sorted(by: Self.resourceOrder).map(Self.semantic)
            value["ageRating"] = try await optionalSingle("/v1/appInfos/\(id)/ageRatingDeclaration").map(Self.semantic) ?? [:]
            infos.append(value)
        }
        protected["appInfos"] = infos
        if let review = try await optionalSingle("/v1/appStoreVersions/\(target.versionID)/appStoreReviewDetail") {
            protected["review"] = Self.semantic(review)
            protected["reviewAttachments"] = try await all("/v1/appStoreReviewDetails/\(Self.id(review))/appStoreReviewAttachments").map(Self.semantic)
        }
        let bytes = try JSONSerialization.data(withJSONObject: protected, options: [.sortedKeys])
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let submission = try await submissionContext(target)
        // Protected values (including demo credentials) are hashed in memory only.
        return ReleaseWorkflowSnapshot(appID: target.appID, bundleID: target.bundleID,
            versionID: target.versionID, platform: target.platform, versionString: versionString,
            buildID: build.id, buildNumber: build.attributes.version,
            buildValid: build.attributes.processingState == "VALID" && build.attributes.expired != true,
            attachedBuildID: attached?["id"] as? String, appleState: state,
            releaseType: attrs["releaseType"] as? String, contentDigest: digest,
            submissionID: submission.id, hasSubmissionConflict: submission.conflict)
    }

    func readiness(_ target: ReleaseWorkflowTarget) async throws -> ReleaseWorkflowValidation {
        try target.validate()
        guard accountKey == target.accountKey else { throw ReleaseWorkflowError.accountChanged }
        let app = try await single("/v1/apps/\(target.appID)")
        guard app["id"] as? String == target.appID,
              (app["attributes"] as? [String: Any])?["bundleId"] as? String == target.bundleID else {
            throw ReleaseWorkflowError.identityChanged
        }
        try await validateContext()
        let payload: ReleaseReadinessPayload
        if let readinessReport { payload = try await readinessReport(target) }
        else {
            // Legacy injected transports do not provide provider evidence and
            // therefore can never silently turn a default web cache into proof.
            let result = try await cli(["validate", "--app", target.appID,
                "--version-id", target.versionID, "--platform", target.platform, "--strict", "--deep", "--output", "json"])
            payload = .init(report: Data(result.stdout.utf8), web: .unavailable(target), exitCode: result.exitCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: payload.report) as? [String: Any] else {
            throw ReleaseWorkflowAPIError.validationUnavailable
        }
        let versions = try await all("/v1/apps/\(target.appID)/appStoreVersions")
        let firstPublication = try ReleaseReadinessPolicy.isFirstPublication(versions: versions, target: target)
        let localizations = try await all("/v1/appStoreVersions/\(target.versionID)/appStoreVersionLocalizations")
        return try ReleaseReadinessPolicy.normalize(report: object, exitCode: payload.exitCode, target: target,
            firstPublication: firstPublication, localizations: localizations, web: payload.web,
            webBindingStable: payload.web.matches(payload.web, target: target))
    }

    func setReleaseMode(_ mode: ReleaseWorkflowMode, target: ReleaseWorkflowTarget) async throws {
        _ = try await request("PATCH", "/v1/appStoreVersions/\(target.versionID)", body: ["data": [
            "type": "appStoreVersions", "id": target.versionID, "attributes": ["releaseType": mode.rawValue]]])
    }

    func submit(_ target: ReleaseWorkflowTarget, expectedContentDigest: String) async throws -> String? {
        // The outer engine persists a consumed boundary before any of these calls.
        // An interrupted partial submission is reconciled by read-only status, never recreated.
        guard !(try await submissionContext(target)).conflict else { throw ReleaseWorkflowError.uncertainOutcome }
        let created = try await request("POST", "/v1/reviewSubmissions", body: ["data": [
            "type": "reviewSubmissions", "attributes": ["platform": target.platform],
            "relationships": ["app": ["data": ["type": "apps", "id": target.appID]]]]])
        guard let submission = created["data"] as? [String: Any] else { throw ReleaseWorkflowAPIError.invalidResponse }
        let submissionID = try Self.id(submission)
        _ = try await request("POST", "/v1/reviewSubmissionItems", body: ["data": [
            "type": "reviewSubmissionItems", "relationships": [
                "reviewSubmission": ["data": ["type": "reviewSubmissions", "id": submissionID]],
                "appStoreVersion": ["data": ["type": "appStoreVersions", "id": target.versionID]]]]])
        let finalSnapshot = try await snapshot(target)
        try finalSnapshot.check(target)
        guard finalSnapshot.contentDigest == expectedContentDigest,
              ASCReleaseStatus.isEditable(finalSnapshot.appleState) else { throw ReleaseWorkflowError.contentChanged }
        _ = try await request("PATCH", "/v1/reviewSubmissions/\(submissionID)", body: ["data": [
            "type": "reviewSubmissions", "id": submissionID, "attributes": ["submitted": true]]])
        return submissionID
    }

    private func submissionContext(_ target: ReleaseWorkflowTarget) async throws -> (id: String?, conflict: Bool) {
        let submissions = try await all("/v1/reviewSubmissions", query: ["filter[app]": target.appID, "include": "app"])
        var matches: [(id: String, date: String)] = []
        var conflict = false
        for submission in submissions {
            guard let attributes = submission["attributes"] as? [String: Any],
                  let platform = attributes["platform"] as? String,
                  let state = attributes["state"] as? String else { throw ReleaseWorkflowAPIError.invalidResponse }
            if let app = Self.relationshipID(submission, "app"), app != target.appID { throw ReleaseWorkflowError.identityChanged }
            guard platform == target.platform else { continue }
            let id = try Self.id(submission)
            // Incomplete/draft submissions also block a fresh POST, even if another
            // client has not attached its version item yet. Never adopt that draft.
            if state != "COMPLETE" { conflict = true }
            let items = try await all("/v1/reviewSubmissions/\(id)/items", query: ["include": "appStoreVersion"])
            if Self.relationshipID(submission, "appStoreVersionForReview") == target.versionID ||
                items.contains(where: { Self.relationshipID($0, "appStoreVersion") == target.versionID }) {
                matches.append((id, attributes["submittedDate"] as? String ?? ""))
            }
        }
        return (matches.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }.first?.id, conflict)
    }

    private static func relationshipID(_ resource: [String: Any], _ name: String) -> String? {
        let relationships = resource["relationships"] as? [String: [String: Any]]
        return (relationships?[name]?["data"] as? [String: Any])?["id"] as? String
    }

    private static func id(_ resource: [String: Any]) throws -> String {
        guard let id = resource["id"] as? String, ReleaseWorkflowTarget.validID(id) else { throw ReleaseWorkflowAPIError.invalidResponse }
        return id
    }
    private static func resourceOrder(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        (lhs["id"] as? String ?? "") < (rhs["id"] as? String ?? "")
    }
    private static func semantic(_ resource: [String: Any]) -> [String: Any] {
        var result = resource.filter { ["id", "type", "attributes"].contains($0.key) }
        if let relationships = resource["relationships"] as? [String: [String: Any]] {
            result["relationships"] = relationships.compactMapValues { $0["data"] }
        }
        return result
    }

    private func optionalSingle(_ path: String) async throws -> [String: Any]? {
        do {
            let object = try await request("GET", path)
            if object["data"] is NSNull { return nil }
            guard let data = object["data"] as? [String: Any] else { throw ReleaseWorkflowAPIError.invalidResponse }
            return data
        } catch ReleaseWorkflowAPIError.httpStatus(404) { return nil }
    }
    private func single(_ path: String) async throws -> [String: Any] {
        guard let value = try await optionalSingle(path) else { throw ReleaseWorkflowAPIError.invalidResponse }
        return value
    }
    private func all(_ endpoint: String, query: [String: String] = [:]) async throws -> [[String: Any]] {
        var initial = URLComponents(); initial.path = endpoint
        initial.queryItems = (["limit": "200"].merging(query) { _, value in value }).sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var next: String? = initial.string
        var seenPages: Set<String> = [], seenIDs: Set<String> = []
        var output: [[String: Any]] = []
        var expectedTotal: Int?
        while let page = next {
            let base = URL(string: "https://api.appstoreconnect.apple.com")!
            guard let url = URL(string: page, relativeTo: base)?.absoluteURL,
                  url.scheme == "https", url.host == base.host, url.port == nil,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.path == endpoint, seenPages.count < 500,
                  seenPages.insert(url.absoluteString).inserted else { throw ReleaseWorkflowAPIError.invalidResponse }
            let pageQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard query.allSatisfy({ key, value in pageQuery.contains { $0.name == key && $0.value == value } &&
                !pageQuery.contains { $0.name == key && $0.value != value } }) else { throw ReleaseWorkflowAPIError.invalidResponse }
            let response = try await request("GET", url.path + (url.query.map { "?" + $0 } ?? ""))
            guard let values = response["data"] as? [[String: Any]] else { throw ReleaseWorkflowAPIError.invalidResponse }
            if let paging = (response["meta"] as? [String: Any])?["paging"] as? [String: Any], let total = paging["total"] as? Int {
                guard total >= 0, expectedTotal == nil || expectedTotal == total else { throw ReleaseWorkflowAPIError.invalidResponse }
                expectedTotal = total
            }
            for resource in values {
                guard seenIDs.insert(try Self.id(resource)).inserted else { throw ReleaseWorkflowAPIError.invalidResponse }
                output.append(resource)
            }
            let nextValue = (response["links"] as? [String: Any])?["next"]
            guard nextValue == nil || nextValue is NSNull || (nextValue as? String)?.isEmpty == false else { throw ReleaseWorkflowAPIError.invalidResponse }
            next = nextValue as? String
        }
        guard expectedTotal == nil || expectedTotal == output.count else { throw ReleaseWorkflowAPIError.invalidResponse }
        return output
    }
    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        try await validateContext()
        let response = try await transport(method, path,
            ["Accept": "application/json", "Content-Type": "application/json"],
            try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) })
        guard (200..<300).contains(response.statusCode) else { throw ReleaseWorkflowAPIError.httpStatus(response.statusCode) }
        if response.body.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              object["errors"] == nil else {
            throw ReleaseWorkflowAPIError.invalidResponse
        }
        return object
    }
}
