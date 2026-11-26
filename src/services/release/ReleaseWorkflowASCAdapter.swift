import CryptoKit
import Foundation

enum ReleaseWorkflowAPIError: Error, LocalizedError {
    case httpStatus(Int), appleResponse(ReleaseAppleError), invalidResponse, validationUnavailable
    var errorDescription: String? {
        switch self {
        case .httpStatus(let status): return L10n.tr("Apple-Anfrage für den Release-Auftrag fehlgeschlagen (HTTP \(status)).")
        case .appleResponse(let error): return L10n.tr("Apple-Anfrage für den Release-Auftrag fehlgeschlagen (HTTP \(error.httpStatus), \(error.codes.joined(separator: ", "))).")
        case .invalidResponse: return L10n.tr("Apple lieferte keine vollständig zuordenbare Release-Antwort.")
        case .validationUnavailable: return L10n.tr("Die vollständige ASC-Release-Prüfung konnte nicht verifiziert werden.")
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
        let submission = try await submissionContext(target, appVersions: versions)
        var reviewProductsReady = true
        if !target.reviewItems.isEmpty {
            let products = try await productSelection(target, submission: submission)
            protected["jointReviewProducts"] = products.protectedContent
            reviewProductsReady = products.diagnostics.isEmpty
        }
        let fingerprints = try Self.fingerprints(protected, checkAgeRatingCorrection: submission.canResume)
        // Protected values (including demo credentials) are hashed in memory only.
        return ReleaseWorkflowSnapshot(appID: target.appID, bundleID: target.bundleID,
            versionID: target.versionID, platform: target.platform, versionString: versionString,
            buildID: build.id, buildNumber: build.attributes.version,
            buildValid: build.attributes.processingState == "VALID" && build.attributes.expired != true,
            attachedBuildID: attached?["id"] as? String, appleState: state,
            releaseType: attrs["releaseType"] as? String, contentDigest: fingerprints.current,
            submissionID: submission.id, hasSubmissionConflict: submission.conflict,
            submissionState: submission.state, canResumeSubmission: submission.canResume, submissionItemID: submission.itemID,
            legacyContentDigests: fingerprints.legacy,
            submissionItemsComplete: submission.complete, reviewItemIDs: submission.reviewItemIDs,
            reviewProductsReady: reviewProductsReady, canResubmitSubmission: submission.canResubmit,
            canResolveSubmission: submission.canResolve, submissionItemStates: submission.itemStates,
            priorIncompleteAgeRatings: fingerprints.incompleteAgeRatings)
    }

    func readiness(_ target: ReleaseWorkflowTarget) async throws -> ReleaseWorkflowValidation {
        try await readiness(target, resubmission: nil)
    }

    func readiness(_ target: ReleaseWorkflowTarget, resubmission: ReleaseResubmissionBinding?) async throws -> ReleaseWorkflowValidation {
        try target.validate()
        let recoverySnapshot: ReleaseWorkflowSnapshot?
        if let resubmission {
            let fresh = try await snapshot(target)
            try fresh.check(target)
            guard resubmission.matches(fresh) else { throw ReleaseWorkflowError.uncertainOutcome }
            recoverySnapshot = fresh
        } else { recoverySnapshot = nil }
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
        let products = target.reviewItems.isEmpty ? nil : try await productSelection(target, submission: try await submissionContext(target, appVersions: versions), allowRetained: resubmission != nil)
        return try ReleaseReadinessPolicy.normalize(report: object, exitCode: payload.exitCode, target: target,
            firstPublication: firstPublication, localizations: localizations, web: payload.web,
            webBindingStable: payload.web.matches(payload.web, target: target), products: products,
            retainedAppVersionState: recoverySnapshot.flatMap { snapshot in
                guard let id = snapshot.submissionItemID, snapshot.submissionItemStates[id] == "ACCEPTED",
                      snapshot.appleState == "ACCEPTED" else { return nil }
                return "ACCEPTED"
            })
    }

    func setReleaseMode(_ mode: ReleaseWorkflowMode, target: ReleaseWorkflowTarget) async throws {
        _ = try await request("PATCH", "/v1/appStoreVersions/\(target.versionID)", body: ["data": [
            "type": "appStoreVersions", "id": target.versionID, "attributes": ["releaseType": mode.rawValue]]])
    }

    private func productSelection(_ target: ReleaseWorkflowTarget, submission: SubmissionContext, allowRetained: Bool = true) async throws -> ReleaseProductSelection.Result {
        let retainedStates: [String: String] = (allowRetained && (submission.canResubmit || submission.canResolve)) ?
            submission.reviewItemIDs.compactMapValues { submission.itemStates[$0] } : [:]
        return try await ReleaseProductSelection.inspect(target: target, retainedReviewStates: retainedStates,
            single: { try await self.optionalSingle($0) }, all: { try await self.all($0, query: $1) })
    }

    func submit(_ target: ReleaseWorkflowTarget, expectedContentDigest: String,
                expectedFingerprintVersion: Int? = 2,
                expectedReleaseMode: ReleaseWorkflowMode = .manual,
                resumingSubmissionID: String? = nil,
                progress: @escaping @Sendable (ReleaseSubmissionProgress) async throws -> Void = { _ in }) async throws -> String? {
        try target.validate()
        // The service has journaled intent and revalidated the entire selected
        // set. Re-read content before creating or extending any Apple draft.
        let before = try await snapshot(target)
        try before.check(target)
        guard before.matchesContentDigest(expectedContentDigest, fingerprintVersion: expectedFingerprintVersion) else {
            throw ReleaseWorkflowError.contentChanged
        }
        guard before.releaseType == expectedReleaseMode.rawValue else { throw ReleaseWorkflowError.uncertainOutcome }
        try await progress(.init(phase: resumingSubmissionID == nil ? .checkingExisting : .verifyingContent, submissionID: resumingSubmissionID))
        let existing = try await submissionContext(target)
        let submissionID: String
        if let resumingSubmissionID {
            guard existing.id == resumingSubmissionID, existing.canResume else { throw ReleaseWorkflowError.uncertainOutcome }
            submissionID = resumingSubmissionID
        } else {
            guard !existing.conflict, ASCReleaseStatus.isEditable(before.appleState) else { throw ReleaseWorkflowError.uncertainOutcome }
            try await progress(.init(phase: .creatingSubmission))
            let created = try await request("POST", "/v1/reviewSubmissions", body: ["data": [
                "type": "reviewSubmissions", "attributes": ["platform": target.platform],
                "relationships": ["app": ["data": ["type": "apps", "id": target.appID]]]]])
            guard let submission = created["data"] as? [String: Any],
                  submission["type"] as? String == "reviewSubmissions" else { throw ReleaseWorkflowAPIError.invalidResponse }
            submissionID = try Self.id(submission)
            try await progress(.init(phase: .submissionCreated, submissionID: submissionID))
        }

        // A partial draft is resumable only through its journaled ID. Reconcile
        // before each missing item; never retry a POST in this invocation after
        // an uncertain response. The next invocation must first read status.
        var current = try await submissionContext(target)
        guard current.id == submissionID, current.canResume else { throw ReleaseWorkflowError.uncertainOutcome }
        var itemID = current.itemID
        var expectedReviewItemIDs = current.reviewItemIDs
        if itemID == nil {
            try await progress(.init(phase: .addingVersion, submissionID: submissionID))
            itemID = try await addItem(submissionID: submissionID, relationship: "appStoreVersion",
                                       type: "appStoreVersions", id: target.versionID)
            try await progress(.init(phase: .versionAdded, submissionID: submissionID, submissionItemID: itemID))
        }
        for selected in target.reviewItems {
            current = try await submissionContext(target)
            guard current.id == submissionID, current.canResume, current.itemID == itemID,
                  expectedReviewItemIDs.allSatisfy({ current.reviewItemIDs[$0.key] == $0.value }) else {
                throw ReleaseWorkflowError.uncertainOutcome
            }
            if let knownID = current.reviewItemIDs[selected.key] {
                guard expectedReviewItemIDs[selected.key] == nil || expectedReviewItemIDs[selected.key] == knownID else {
                    throw ReleaseWorkflowError.uncertainOutcome
                }
                expectedReviewItemIDs[selected.key] = knownID
                // Include reconciled IDs in the durable journal as well.
                try await progress(.init(phase: .reviewItemAdded, submissionID: submissionID, submissionItemID: itemID,
                                         reviewItem: selected, reviewItemID: knownID))
                continue
            }
            try await progress(.init(phase: .addingReviewItem, submissionID: submissionID, submissionItemID: itemID,
                                     reviewItem: selected))
            let addedID = try await addItem(submissionID: submissionID, relationship: selected.relationshipName,
                                           type: selected.type.rawValue, id: selected.id)
            expectedReviewItemIDs[selected.key] = addedID
            try await progress(.init(phase: .reviewItemAdded, submissionID: submissionID, submissionItemID: itemID,
                                     reviewItem: selected, reviewItemID: addedID))
        }
        try await progress(.init(phase: .verifyingContent, submissionID: submissionID, submissionItemID: itemID))
        let finalSnapshot = try await snapshot(target)
        try finalSnapshot.check(target)
        guard finalSnapshot.matchesContentDigest(expectedContentDigest, fingerprintVersion: expectedFingerprintVersion) else { throw ReleaseWorkflowError.contentChanged }
        guard finalSnapshot.submissionID == submissionID, finalSnapshot.submissionItemID == itemID,
              finalSnapshot.submissionItemsComplete, finalSnapshot.canResumeSubmission,
              finalSnapshot.reviewProductsReady,
              finalSnapshot.reviewItemIDs == expectedReviewItemIDs,
              finalSnapshot.releaseType == expectedReleaseMode.rawValue,
              ASCReleaseStatus.isEditable(finalSnapshot.appleState) || ASCReleaseStatus.normalize(finalSnapshot.appleState) == "READY_FOR_REVIEW" else {
            throw ReleaseWorkflowError.uncertainOutcome
        }
        try await progress(.init(phase: .submitting, submissionID: submissionID, submissionItemID: itemID))
        let accepted = try await request("PATCH", "/v1/reviewSubmissions/\(submissionID)", body: ["data": [
            "type": "reviewSubmissions", "id": submissionID, "attributes": ["submitted": true]]])
        guard let response = accepted["data"] as? [String: Any], response["id"] as? String == submissionID,
              response["type"] as? String == "reviewSubmissions" else { throw ReleaseWorkflowAPIError.invalidResponse }
        try await progress(.init(phase: .acknowledged, submissionID: submissionID, submissionItemID: itemID))
        return submissionID
    }

    /// Only the explicitly confirmed rejected items are marked resolved. The
    /// enclosing review and every item identity stay fixed throughout the attempt.
    func resubmit(_ target: ReleaseWorkflowTarget, binding: ReleaseResubmissionBinding,
                  expectedContentDigest: String, expectedFingerprintVersion: Int?, expectedReleaseMode: ReleaseWorkflowMode,
                  progress: @escaping @Sendable (ReleaseSubmissionProgress) async throws -> Void) async throws -> String? {
        try target.validate()
        let authorizedIDs = Set([binding.submissionItemID] + Array(binding.reviewItemIDs.values))
        guard ReleaseWorkflowTarget.validID(binding.submissionID), ReleaseWorkflowTarget.validID(binding.submissionItemID),
              ReleaseWorkflowTarget.validID(binding.previousOperationID),
              Set(binding.reviewItemIDs.keys) == Set(target.reviewItems.map(\.key)),
              Set(binding.itemIDsToResolve ?? []).isSubset(of: authorizedIDs),
              (binding.itemIDsToResolve ?? []).allSatisfy({ binding.itemStates?[$0] == "REJECTED" }) else { throw ReleaseWorkflowError.invalidTarget }
        func checkedSnapshot() async throws -> ReleaseWorkflowSnapshot {
            let fresh = try await snapshot(target)
            try fresh.check(target)
            guard fresh.matchesContentDigest(expectedContentDigest, fingerprintVersion: expectedFingerprintVersion) else {
                throw ReleaseWorkflowError.contentChanged
            }
            guard binding.matches(fresh), fresh.reviewProductsReady, fresh.releaseType == expectedReleaseMode.rawValue else {
                throw ReleaseWorkflowError.uncertainOutcome
            }
            return fresh
        }
        try await progress(.init(phase: .verifyingContent, submissionID: binding.submissionID, submissionItemID: binding.submissionItemID))
        for id in (binding.itemIDsToResolve ?? []).sorted() {
            let fresh = try await checkedSnapshot()
            // A previous timed-out write may have been confirmed by read-only status.
            if fresh.submissionItemStates[id] == "READY_FOR_REVIEW" { continue }
            guard fresh.submissionItemStates[id] == "REJECTED" else { throw ReleaseWorkflowError.uncertainOutcome }
            try await progress(.init(phase: .resolvingReviewItem, submissionID: binding.submissionID,
                                     submissionItemID: binding.submissionItemID, resolvedItemID: id))
            let result = try await request("PATCH", "/v1/reviewSubmissionItems/\(id)", body: ["data": [
                "type": "reviewSubmissionItems", "id": id, "attributes": ["resolved": true]]])
            guard let item = result["data"] as? [String: Any], item["id"] as? String == id,
                  item["type"] as? String == "reviewSubmissionItems" else { throw ReleaseWorkflowAPIError.invalidResponse }
            let after = try await checkedSnapshot()
            guard after.submissionItemStates[id] == "READY_FOR_REVIEW" else { throw ReleaseWorkflowError.uncertainOutcome }
            try await progress(.init(phase: .reviewItemResolved, submissionID: binding.submissionID,
                                     submissionItemID: binding.submissionItemID, resolvedItemID: id))
        }
        let ready = try await checkedSnapshot()
        guard ready.canResubmitSubmission else { throw ReleaseWorkflowError.uncertainOutcome }
        try await progress(.init(phase: .submitting, submissionID: binding.submissionID, submissionItemID: binding.submissionItemID))
        let accepted = try await request("PATCH", "/v1/reviewSubmissions/\(binding.submissionID)", body: ["data": [
            "type": "reviewSubmissions", "id": binding.submissionID, "attributes": ["submitted": true]]])
        guard let response = accepted["data"] as? [String: Any], response["id"] as? String == binding.submissionID,
              response["type"] as? String == "reviewSubmissions" else { throw ReleaseWorkflowAPIError.invalidResponse }
        try await progress(.init(phase: .acknowledged, submissionID: binding.submissionID, submissionItemID: binding.submissionItemID))
        return binding.submissionID
    }

    private func addItem(submissionID: String, relationship: String, type: String, id: String) async throws -> String {
        let added = try await request("POST", "/v1/reviewSubmissionItems", body: ["data": [
            "type": "reviewSubmissionItems", "relationships": [
                "reviewSubmission": ["data": ["type": "reviewSubmissions", "id": submissionID]],
                relationship: ["data": ["type": type, "id": id]]]]])
        guard let item = added["data"] as? [String: Any], item["type"] as? String == "reviewSubmissionItems" else {
            throw ReleaseWorkflowAPIError.invalidResponse
        }
        return try Self.id(item)
    }

    private struct SubmissionContext {
        var id: String?
        var state: String?
        var conflict = false
        var canResume = false
        var canResubmit = false
        var canResolve = false
        var itemStates: [String: String] = [:]
        var itemID: String?
        var complete = false
        var reviewItemIDs: [String: String] = [:]
    }

    private func submissionContext(_ target: ReleaseWorkflowTarget, appVersions: [[String: Any]]? = nil) async throws -> SubmissionContext {
        let submissions = try await all("/v1/reviewSubmissions", query: ["filter[app]": target.appID, "include": "app"])
        var matches: [(id: String, state: String, date: String, draft: Bool, resubmission: Bool, resolution: Bool, contents: ReleaseSubmissionContents)] = []
        var activeCount = 0
        var versions = appVersions
        for submission in submissions {
            guard let attributes = submission["attributes"] as? [String: Any],
                  let state = attributes["state"] as? String else { throw ReleaseWorkflowAPIError.invalidResponse }
            if let app = Self.relationshipID(submission, "app"), app != target.appID { throw ReleaseWorkflowError.identityChanged }
            let platform = attributes["platform"] as? String
            if let platform, platform != target.platform { continue }
            let id = try Self.id(submission)
            let includes = target.reviewItems.isEmpty ? "appStoreVersion" :
                "appStoreVersion,inAppPurchaseVersion,subscriptionVersion,subscriptionGroupVersion"
            let items = try await all("/v1/reviewSubmissions/\(id)/items", query: ["include": includes])
            if platform == nil {
                // Apple can retain undated, empty drafts for an already released version with a null platform.
                guard submission["type"] as? String == "reviewSubmissions",
                      attributes["platform"] is NSNull, attributes["submittedDate"] is NSNull,
                      state == "READY_FOR_REVIEW", items.isEmpty,
                      Self.relationshipID(submission, "app", type: "apps") == target.appID else {
                    throw ReleaseWorkflowAPIError.invalidResponse
                }
                // On a newly created platform-specific draft Apple may expand this relationship to the live version.
                // Request it only to corroborate the identity of a platformless draft.
                let detail = try await single("/v1/reviewSubmissions/\(id)?include=app,appStoreVersionForReview")
                guard detail["type"] as? String == "reviewSubmissions", detail["id"] as? String == id,
                      Self.relationshipID(detail, "app", type: "apps") == target.appID,
                      let detailAttributes = detail["attributes"] as? [String: Any],
                      detailAttributes["platform"] is NSNull, detailAttributes["submittedDate"] is NSNull,
                      detailAttributes["state"] as? String == state,
                      let oldID = Self.relationshipID(detail, "appStoreVersionForReview", type: "appStoreVersions"),
                      oldID != target.versionID else { throw ReleaseWorkflowAPIError.invalidResponse }
                if versions == nil { versions = try await all("/v1/apps/\(target.appID)/appStoreVersions") }
                guard let versions, Self.isPublishedPredecessor(oldID, of: target, in: versions) else {
                    throw ReleaseWorkflowAPIError.invalidResponse
                }
                continue
            }
            if state != "COMPLETE" { activeCount += 1 }
            let contents = ReleaseSubmissionContents(items: items, target: target, submissionID: id)
            let forReview = Self.relationshipID(submission, "appStoreVersionForReview")
            let matchingVersion = forReview == target.versionID || contents.referencesAppVersion
            // A unique subset (including an empty draft) may be reported, but the
            // service requires the saved create acknowledgement to adopt it.
            let possiblePartial = state != "COMPLETE" && contents.validSelection && (forReview == nil || forReview == target.versionID)
            guard matchingVersion || possiblePartial else { continue }
            let submittedDate = attributes["submittedDate"] as? String ?? ""
            let draft = state == "READY_FOR_REVIEW" && submittedDate.isEmpty && contents.ready &&
                (forReview == nil || forReview == target.versionID)
            // UNRESOLVED_ISSUES proves a completed first review. All items must
            // already have been resolved, while the historical submitted date remains.
            let resubmission = state == "UNRESOLVED_ISSUES" && !submittedDate.isEmpty && contents.canResubmit &&
                (forReview == nil || forReview == target.versionID)
            let resolution = state == "UNRESOLVED_ISSUES" && !submittedDate.isEmpty && contents.canResolve &&
                (forReview == nil || forReview == target.versionID)
            matches.append((id, state, submittedDate, draft, resubmission, resolution, contents))
        }
        let active = matches.filter { $0.state != "COMPLETE" }
        guard active.count <= 1 else { throw ReleaseWorkflowAPIError.invalidResponse }
        let chosen = active.first ?? matches.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }.first
        return SubmissionContext(id: chosen?.id, state: chosen?.state, conflict: activeCount > 0,
            canResume: activeCount == 1 && chosen?.draft == true,
            canResubmit: activeCount == 1 && chosen?.resubmission == true,
            canResolve: activeCount == 1 && chosen?.resolution == true, itemStates: chosen?.contents.itemStates ?? [:], itemID: chosen?.contents.appItemID,
            complete: chosen?.contents.complete == true, reviewItemIDs: chosen?.contents.reviewItemIDs ?? [:])
    }

    /// V2 excludes only Apple's app-info lifecycle state. Old journals remain
    /// immutable: bounded candidate hashes prove their complete old protected
    /// document, changing only this known READY_FOR_REVIEW transition. A metadata
    /// edit, locale/asset reorder or other field change still changes every hash.
    static func fingerprints(_ protected: [String: Any], checkAgeRatingCorrection: Bool) throws
        -> (current: String, legacy: Set<String>, incompleteAgeRatings: [String: ReleaseAgeRatingCorrection]) {
        func digest(_ object: [String: Any]) throws -> String {
            SHA256.hash(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                .map { String(format: "%02x", $0) }.joined()
        }
        let infos = protected["appInfos"] as? [[String: Any]] ?? []
        var normalized = protected
        normalized["appInfos"] = infos.map { info in
            var value = info
            if var attrs = value["attributes"] as? [String: Any] {
                attrs.removeValue(forKey: "state"); value["attributes"] = attrs
            }
            return value
        }
        var legacy = Set([try digest(protected)])
        let candidates = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "READY_FOR_REVIEW"]
        let changing = infos.indices.filter { (infos[$0]["attributes"] as? [String: Any])?["state"] as? String == "READY_FOR_REVIEW" }
        // At most 216 variants; large/ambiguous histories require fresh preparation.
        if changing.count <= 3 {
            var variants = [infos]
            for index in changing {
                variants = variants.flatMap { value in
                    candidates.map { state in
                        var next = value
                        var attrs = next[index]["attributes"] as? [String: Any] ?? [:]
                        attrs["state"] = state; next[index]["attributes"] = attrs
                        return next
                    }
                }
            }
            for infos in variants {
                var value = protected; value["appInfos"] = infos
                legacy.insert(try digest(value))
            }
        }
        let incomplete = checkAgeRatingCorrection ? try ReleaseAgeRatingCorrection.priorFingerprints(in: normalized, digest: digest) : [:]
        return (try digest(normalized), legacy, incomplete)
    }

    private static func isPublishedPredecessor(_ id: String, of target: ReleaseWorkflowTarget, in versions: [[String: Any]]) -> Bool {
        guard let previous = versions.first(where: { $0["id"] as? String == id }),
              previous["type"] as? String == "appStoreVersions",
              let previousAttributes = previous["attributes"] as? [String: Any],
              previousAttributes["platform"] as? String == target.platform,
              let previousNumber = previousAttributes["versionString"] as? String,
              let current = versions.first(where: { $0["id"] as? String == target.versionID }),
              let currentAttributes = current["attributes"] as? [String: Any],
              currentAttributes["platform"] as? String == target.platform,
              let currentNumber = currentAttributes["versionString"] as? String else { return false }
        let state = previousAttributes["appVersionState"] as? String ?? previousAttributes["appStoreState"] as? String ?? ""
        return ASCReleaseStatus.publishedStates.contains(state) &&
            ReleaseAutomationService.compareVersions(previousNumber, currentNumber) == .orderedAscending
    }

    private static func relationshipID(_ resource: [String: Any], _ name: String, type: String? = nil) -> String? {
        let relationships = resource["relationships"] as? [String: [String: Any]]
        guard let data = relationships?[name]?["data"] as? [String: Any] else { return nil }
        if let type, data["type"] as? String != type { return nil }
        return data["id"] as? String
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
        catch ReleaseWorkflowAPIError.appleResponse(let error) where error.httpStatus == 404 { return nil }
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
        guard (200..<300).contains(response.statusCode) else {
            throw ReleaseWorkflowAPIError.appleResponse(.sanitized(status: response.statusCode, body: response.body))
        }
        if response.body.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              object["errors"] == nil else {
            throw ReleaseWorkflowAPIError.invalidResponse
        }
        return object
    }
}
