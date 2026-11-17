import CryptoKit
import Darwin
import Foundation

/// An explicit, reviewable product metadata version. Parent product IDs are not
/// interchangeable with version IDs, and a release never adopts all pending products.
struct ReleaseReviewItem: Codable, Hashable, Sendable {
    enum ResourceType: String, Codable, CaseIterable, Sendable {
        case inAppPurchaseVersions, subscriptionVersions, subscriptionGroupVersions

        var relationshipName: String {
            switch self {
            case .inAppPurchaseVersions: return "inAppPurchaseVersion"
            case .subscriptionVersions: return "subscriptionVersion"
            case .subscriptionGroupVersions: return "subscriptionGroupVersion"
            }
        }
    }
    typealias Kind = ResourceType
    let type: ResourceType
    let id: String
    var key: String { "\(type.rawValue):\(id)" }
    var relationshipName: String { type.relationshipName }
}

/// A release belongs to this identity, never to the currently visible Blitz tab.
struct ReleaseWorkflowTarget: Codable, Equatable, Sendable {
    let projectID: String
    let projectPath: String
    let appID: String
    let bundleID: String
    let platform: String
    let accountKey: String
    let versionID: String
    let buildID: String
    let releaseTargetID: String?
    let reviewItems: [ReleaseReviewItem]

    init(projectID: String, projectPath: String, appID: String, bundleID: String, platform: String,
         accountKey: String, versionID: String, buildID: String, releaseTargetID: String? = nil,
         reviewItems: [ReleaseReviewItem] = []) {
        self.projectID = projectID; self.projectPath = projectPath
        self.appID = appID; self.bundleID = bundleID; self.platform = platform
        self.accountKey = accountKey; self.versionID = versionID; self.buildID = buildID
        self.releaseTargetID = releaseTargetID
        self.reviewItems = reviewItems.sorted { $0.key < $1.key }
    }
    enum CodingKeys: String, CodingKey {
        case projectID = "projectId", projectPath, appID = "appId", bundleID = "bundleId", platform, accountKey
        case versionID = "versionId", buildID = "buildId", releaseTargetID = "releaseTargetId", reviewItems
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(projectID: try c.decode(String.self, forKey: .projectID),
            projectPath: try c.decode(String.self, forKey: .projectPath),
            appID: try c.decode(String.self, forKey: .appID), bundleID: try c.decode(String.self, forKey: .bundleID),
            platform: try c.decode(String.self, forKey: .platform), accountKey: try c.decode(String.self, forKey: .accountKey),
            versionID: try c.decode(String.self, forKey: .versionID), buildID: try c.decode(String.self, forKey: .buildID),
            releaseTargetID: try c.decodeIfPresent(String.self, forKey: .releaseTargetID),
            reviewItems: try c.decodeIfPresent([ReleaseReviewItem].self, forKey: .reviewItems) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectID, forKey: .projectID); try c.encode(projectPath, forKey: .projectPath)
        try c.encode(appID, forKey: .appID); try c.encode(bundleID, forKey: .bundleID)
        try c.encode(platform, forKey: .platform); try c.encode(accountKey, forKey: .accountKey)
        try c.encode(versionID, forKey: .versionID); try c.encode(buildID, forKey: .buildID)
        try c.encodeIfPresent(releaseTargetID, forKey: .releaseTargetID)
        // The exact bytes of existing app-only confirmation documents stay valid.
        if !reviewItems.isEmpty { try c.encode(reviewItems, forKey: .reviewItems) }
    }

    func validate() throws {
        guard !projectID.isEmpty, !bundleID.isEmpty, !accountKey.isEmpty,
              releaseTargetID.map(Self.validID) ?? true,
              ["IOS", "MAC_OS", "TV_OS", "VISION_OS"].contains(platform),
              [appID, versionID, buildID].allSatisfy(Self.validID),
              reviewItems.count <= 199, Set(reviewItems).count == reviewItems.count,
              reviewItems.allSatisfy({ Self.validID($0.id) }),
              projectPath.hasPrefix("/"),
              URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().path == projectPath else {
            throw ReleaseWorkflowError.invalidTarget
        }
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

enum ReleaseWorkflowMode: String, Codable, Sendable {
    case manual = "MANUAL"
    case automaticAfterApproval = "AFTER_APPROVAL"
}

struct ReleaseWorkflowSnapshot: Equatable, Sendable {
    let appID: String
    let bundleID: String
    let versionID: String
    let platform: String
    let versionString: String
    let buildID: String
    let buildNumber: String
    let buildValid: Bool
    let attachedBuildID: String?
    let appleState: String
    let releaseType: String?
    /// Digest of all protected metadata/media, not their plaintext or demo credentials.
    let contentDigest: String
    var submissionID: String? = nil
    var hasSubmissionConflict: Bool = false
    var submissionState: String? = nil
    var canResumeSubmission: Bool = false
    var submissionItemID: String? = nil
    var legacyContentDigests: Set<String> = []
    /// False for a proven subset/empty draft. Such drafts require a journaled
    /// submission ID; they may never be adopted from a matching app alone.
    var submissionItemsComplete: Bool = true
    var reviewItemIDs: [String: String] = [:]
    var reviewProductsReady: Bool = true
    /// A previously submitted, rejected review whose exact complete item set has
    /// already been resolved in App Store Connect. This is never draft recovery.
    var canResubmitSubmission: Bool = false
    var canResolveSubmission: Bool = false
    var submissionItemStates: [String: String] = [:]

    static let submittedAppleStates: Set<String> = ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE",
        "PENDING_APPLE_RELEASE", "PROCESSING_FOR_APP_STORE", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "ACCEPTED"]

    var currentlySubmitted: Bool {
        ["WAITING_FOR_REVIEW", "IN_REVIEW", "COMPLETING", "COMPLETE"].contains(submissionState ?? "") &&
            Self.submittedAppleStates.contains(ASCReleaseStatus.normalize(appleState))
    }

    func matchesContentDigest(_ digest: String, fingerprintVersion: Int?) -> Bool {
        if fingerprintVersion == 2 { return contentDigest == digest }
        guard fingerprintVersion == nil else { return false }
        return legacyContentDigests.isEmpty ? contentDigest == digest : legacyContentDigests.contains(digest)
    }

    func check(_ target: ReleaseWorkflowTarget, requirePreparedBuild: Bool = true) throws {
        guard appID == target.appID, bundleID == target.bundleID,
              versionID == target.versionID, platform == target.platform,
              buildID == target.buildID,
              (!requirePreparedBuild || (buildValid && attachedBuildID == target.buildID)) else {
            throw ReleaseWorkflowError.identityChanged
        }
    }
}

struct ReleaseWorkflowValidation: Codable, Equatable, Sendable {
    let ready: Bool
    let blocking: Int
    let warnings: Int
    let unverified: Int
    /// Stable identifiers and generated diagnostics only; never persist raw CLI/review data.
    let checkIDs: [String]
    var diagnostics: [ReleaseReadinessDiagnostic]? = nil
}

protocol ReleaseWorkflowAPI {
    var accountKey: String { get }
    func snapshot(_ target: ReleaseWorkflowTarget) async throws -> ReleaseWorkflowSnapshot
    func readiness(_ target: ReleaseWorkflowTarget) async throws -> ReleaseWorkflowValidation
    func readiness(_ target: ReleaseWorkflowTarget, resubmission: ReleaseResubmissionBinding?) async throws -> ReleaseWorkflowValidation
    func setReleaseMode(_ mode: ReleaseWorkflowMode, target: ReleaseWorkflowTarget) async throws
    func submit(_ target: ReleaseWorkflowTarget, expectedContentDigest: String,
                expectedFingerprintVersion: Int?, expectedReleaseMode: ReleaseWorkflowMode, resumingSubmissionID: String?,
                progress: @escaping @Sendable (ReleaseSubmissionProgress) async throws -> Void) async throws -> String?
    func resubmit(_ target: ReleaseWorkflowTarget, binding: ReleaseResubmissionBinding,
                  expectedContentDigest: String, expectedFingerprintVersion: Int?, expectedReleaseMode: ReleaseWorkflowMode,
                  progress: @escaping @Sendable (ReleaseSubmissionProgress) async throws -> Void) async throws -> String?
}

extension ReleaseWorkflowAPI {
    func readiness(_ target: ReleaseWorkflowTarget, resubmission: ReleaseResubmissionBinding?) async throws -> ReleaseWorkflowValidation {
        try await readiness(target)
    }
    func resubmit(_ target: ReleaseWorkflowTarget, binding: ReleaseResubmissionBinding,
                  expectedContentDigest: String, expectedFingerprintVersion: Int?, expectedReleaseMode: ReleaseWorkflowMode,
                  progress: @escaping @Sendable (ReleaseSubmissionProgress) async throws -> Void) async throws -> String? {
        throw ReleaseWorkflowError.unsafeState
    }
}

/// A fresh attempt binds the existing review and its complete item identities.
/// The prior acknowledged operation and its fingerprint remain unchanged.
struct ReleaseResubmissionBinding: Codable, Equatable, Sendable {
    let previousOperationID: String
    let submissionID: String
    let submissionItemID: String
    let reviewItemIDs: [String: String]
    var itemIDsToResolve: [String]? = nil
    var itemStates: [String: String]? = nil

    /// State changes may only be the approved REJECTED → READY_FOR_REVIEW transitions.
    func matches(_ snapshot: ReleaseWorkflowSnapshot) -> Bool {
        guard snapshot.submissionID == submissionID, snapshot.submissionItemID == submissionItemID,
              snapshot.reviewItemIDs == reviewItemIDs, snapshot.submissionItemsComplete,
              snapshot.canResubmitSubmission || (itemIDsToResolve?.isEmpty == false && snapshot.canResolveSubmission) else { return false }
        guard let itemStates else { return snapshot.canResubmitSubmission }
        guard Set(itemStates.keys) == Set(snapshot.submissionItemStates.keys) else { return false }
        return itemStates.allSatisfy { id, state in
            snapshot.submissionItemStates[id] == state ||
                (state == "REJECTED" && itemIDsToResolve?.contains(id) == true && snapshot.submissionItemStates[id] == "READY_FOR_REVIEW")
        }
    }

    enum CodingKeys: String, CodingKey {
        case previousOperationID = "previousOperationId", submissionID = "submissionId"
        case submissionItemID = "submissionItemId", reviewItemIDs, itemIDsToResolve, itemStates
    }
}

enum ReleaseWorkflowState: String, Codable, Sendable {
    case prepared, validated, needsPreparation, attachmentPending, releaseModePending, submissionPending, submitted
}

struct ReleaseWorkflowRecord: Codable, Equatable, Sendable {
    let operationID: String
    let target: ReleaseWorkflowTarget
    let mode: ReleaseWorkflowMode
    let versionString: String
    let buildNumber: String
    let contentDigest: String
    let confirmationDigest: String
    let preparedAt: Date
    var updatedAt: Date
    var state: ReleaseWorkflowState
    var validation: ReleaseWorkflowValidation?
    var lastErrorCode: String?
    var appleState: String?
    var submissionID: String?
    var submissionProgress: ReleaseSubmissionProgress? = nil
    var lastDiagnostic: ReleaseSubmissionDiagnostic? = nil
    var resumableSubmissionID: String? = nil
    var submissionItemID: String? = nil
    var contentFingerprintVersion: Int? = nil
    var requiresLegacyRecoveryConfirmation: Bool? = nil
    /// Resource key -> reviewSubmissionItem ID, persisted after every confirmed
    /// add. Optional only for decoding journals written before joint submissions.
    var reviewItemIDs: [String: String]? = nil
    var resubmission: ReleaseResubmissionBinding? = nil
    /// Current Apple review state, distinct from the historical local write state.
    var submissionState: String? = nil
    var resubmittableSubmissionID: String? = nil
    var resolvableSubmissionID: String? = nil
    var resumableResubmissionID: String? = nil
    var submissionItemStates: [String: String]? = nil
    var reviewOutcome: String? = nil
    var nextAction: String? = nil
    enum CodingKeys: String, CodingKey {
        case operationID = "operationId", target, mode, versionString, buildNumber, contentDigest, confirmationDigest
        case preparedAt, updatedAt, state, validation, lastErrorCode, appleState, submissionID = "submissionId"
        case submissionProgress, lastDiagnostic
        case resumableSubmissionID = "resumableSubmissionId"
        case submissionItemID = "submissionItemId"
        case contentFingerprintVersion
        case requiresLegacyRecoveryConfirmation, reviewItemIDs, resubmission, submissionState
        case resubmittableSubmissionID = "resubmittableSubmissionId"
        case resolvableSubmissionID = "resolvableSubmissionId", resumableResubmissionID = "resumableResubmissionId"
        case submissionItemStates, reviewOutcome, nextAction
    }
}

enum ReleaseWorkflowError: Error, LocalizedError {
    case invalidTarget, accountChanged, identityChanged, contentChanged, buildNotPrepared
    case unknownOperation, busy, unsafeState, confirmationRequired, notReady, uncertainOutcome, storage
    case submissionFailed(ReleaseSubmissionDiagnostic)
    var errorDescription: String? {
        switch self {
        case .invalidTarget: return L10n.tr("Der Release-Auftrag benötigt eindeutige Projekt-, Konto-, App-, Plattform-, Versions- und Build-IDs.")
        case .accountChanged: return L10n.tr("Der Release-Auftrag gehört zu einem anderen Apple-Konto.")
        case .identityChanged: return L10n.tr("App, Plattform, Version oder zugeordneter Build stimmen nicht mit dem Release-Auftrag überein.")
        case .contentChanged: return L10n.tr("Texte, Medien oder Release-Daten haben sich geändert. Bitte erneut vorbereiten und prüfen.")
        case .buildNotPrepared: return L10n.tr("Zuerst die genaue Version mit einem verarbeiteten, passenden Build vorbereiten und verknüpfen.")
        case .unknownOperation: return L10n.tr("Der Release-Auftrag wurde nicht gefunden.")
        case .busy: return L10n.tr("Für diese App und Plattform läuft bereits ein Release-Schritt.")
        case .unsafeState: return L10n.tr("Der gespeicherte Release-Zustand ist ungültig oder nicht mehr aktiv.")
        case .confirmationRequired: return L10n.tr("Der Bestätigungswert muss genau dem geprüften Release-Auftrag entsprechen.")
        case .notReady: return L10n.tr("Die frische Release-Prüfung hat offene oder nicht verifizierte Punkte gefunden.")
        case .uncertainOutcome: return L10n.tr("Ein vorheriger Schreibauftrag hat einen unklaren Ausgang. Nur den Status abgleichen; nicht erneut einreichen.")
        case .submissionFailed(let diagnostic): return diagnostic.message
        case .storage: return L10n.tr("Der private Release-Zustand konnte nicht sicher gespeichert werden.")
        }
    }
}

/// Persistent boundaries survive new chats, helper processes and app restarts.
/// All network effects remain in a captured account-bound API implementation.
actor ReleaseWorkflowService {
    private let directory: URL
    private let api: any ReleaseWorkflowAPI

    init(directory: URL, api: any ReleaseWorkflowAPI) {
        self.directory = directory
        self.api = api
    }

    /// Local inspection only; callers can verify registration/account before any API access.
    func loadRecord(operationID: String) throws -> ReleaseWorkflowRecord { try load(operationID) }

    func activeOperation(target: ReleaseWorkflowTarget) throws -> ReleaseWorkflowRecord? {
        try target.validate()
        try checkAccount(target.accountKey, target: target)
        return try activeRecord(target)
    }

    func prepare(target: ReleaseWorkflowTarget, mode: ReleaseWorkflowMode,
                 preserveReviewSelection: Bool = false) async throws -> ReleaseWorkflowRecord {
        try await prepareInternal(target: target, mode: mode, attach: nil, preserveReviewSelection: preserveReviewSelection)
    }

    /// Explicit UI action only. MCP/CLI `release_prepare` never attaches a build.
    /// The existing manager supplies its checked attachment operation; the same
    /// process lock and durable intent cover it before final preparation begins.
    func prepareAfterAttachingBuild(target: ReleaseWorkflowTarget, mode: ReleaseWorkflowMode,
                                   preserveReviewSelection: Bool = false,
                                   attach: @escaping () async throws -> Void) async throws -> ReleaseWorkflowRecord {
        try await prepareInternal(target: target, mode: mode, attach: attach, preserveReviewSelection: preserveReviewSelection)
    }

    private func prepareInternal(target: ReleaseWorkflowTarget, mode: ReleaseWorkflowMode,
                                 attach: (() async throws -> Void)?, preserveReviewSelection: Bool) async throws -> ReleaseWorkflowRecord {
        try target.validate()
        try checkAccount(target.accountKey, target: target)
        let lock = try acquire(target); defer { release(lock) }
        let previous = try activeRecord(target)
        // App-only UI entry points must not silently replace a jointly prepared
        // selection. The check belongs under the same lock as the new journal.
        if preserveReviewSelection, let previous, previous.state != .submitted,
           previous.target.reviewItems != target.reviewItems { throw ReleaseWorkflowError.unsafeState }
        if let previous, previous.state == .submissionPending || previous.state == .releaseModePending || previous.state == .attachmentPending {
            // A new operation ID must not bypass a consumed mutation boundary.
            throw ReleaseWorkflowError.uncertainOutcome
        }
        let snapshot = try await api.snapshot(target)
        try snapshot.check(target, requirePreparedBuild: attach == nil)
        guard snapshot.buildValid else { throw ReleaseWorkflowError.buildNotPrepared }
        guard !snapshot.hasSubmissionConflict else { throw ReleaseWorkflowError.uncertainOutcome }
        guard ASCReleaseStatus.isEditable(snapshot.appleState) else { throw ReleaseWorkflowError.buildNotPrepared }
        if let previous, previous.target == target, previous.mode == mode,
           snapshot.attachedBuildID == target.buildID,
           snapshot.matchesContentDigest(previous.contentDigest, fingerprintVersion: previous.contentFingerprintVersion), previous.versionString == snapshot.versionString,
           previous.buildNumber == snapshot.buildNumber,
           previous.state == .prepared || previous.state == .validated {
            return previous
        }
        let id = UUID().uuidString.lowercased()
        let now = Date()
        let digest = try Self.digest(Confirmation(target: target, mode: mode, operationID: id,
            versionString: snapshot.versionString, buildNumber: snapshot.buildNumber, contentDigest: snapshot.contentDigest, contentFingerprintVersion: 2))
        var record = ReleaseWorkflowRecord(operationID: id, target: target, mode: mode,
            versionString: snapshot.versionString, buildNumber: snapshot.buildNumber,
            contentDigest: snapshot.contentDigest, confirmationDigest: digest, preparedAt: now,
            updatedAt: now, state: .prepared, appleState: snapshot.appleState, contentFingerprintVersion: 2)
        try save(record)
        try write(Data(id.utf8), to: activeURL(target))
        if let attach, snapshot.attachedBuildID != target.buildID {
            record.state = .attachmentPending
            try save(record)
            do {
                try await attach()
                let after = try await api.snapshot(target)
                try checkUnchanged(after, record: record)
                record.state = .prepared
                record.updatedAt = Date()
                try save(record)
            } catch { throw ReleaseWorkflowError.uncertainOutcome }
        }
        return record
    }

    /// Prepare a new confirmation for the exact rejected review. An explicit
    /// resolution plan names its rejected items; preparation never writes Apple.
    func prepareResubmission(operationID: String, accountKey: String, submissionID: String, resolveRejectedItems: Bool = false) async throws -> ReleaseWorkflowRecord {
        let previous = try load(operationID)
        try checkAccount(accountKey, target: previous.target)
        guard ReleaseWorkflowTarget.validID(submissionID) else { throw ReleaseWorkflowError.invalidTarget }
        let lock = try acquire(previous.target); defer { release(lock) }
        guard let active = try activeRecord(previous.target) else { throw ReleaseWorkflowError.unsafeState }
        guard previous.state == .submitted, previous.submissionProgress?.phase == .acknowledged,
              previous.submissionID == submissionID,
              active.operationID == previous.operationID ||
                (active.resubmission?.previousOperationID == previous.operationID &&
                 [.prepared, .validated, .needsPreparation].contains(active.state)) else {
            throw ReleaseWorkflowError.unsafeState
        }
        let snapshot = try await api.snapshot(previous.target)
        try snapshot.check(previous.target)
        guard canPrepareResubmission(snapshot, record: previous, resolveRejectedItems: resolveRejectedItems), let itemID = snapshot.submissionItemID else {
            throw ReleaseWorkflowError.uncertainOutcome
        }
        let binding = ReleaseResubmissionBinding(previousOperationID: previous.operationID,
            submissionID: submissionID, submissionItemID: itemID, reviewItemIDs: snapshot.reviewItemIDs,
            itemIDsToResolve: resolveRejectedItems ? snapshot.submissionItemStates.filter { $0.value == "REJECTED" }.keys.sorted() : nil,
            itemStates: snapshot.submissionItemStates.isEmpty ? nil : snapshot.submissionItemStates)
        if active.resubmission == binding,
           active.contentDigest == snapshot.contentDigest, active.state == .prepared || active.state == .validated {
            return active
        }
        let id = UUID().uuidString.lowercased(), now = Date()
        let digest = try Self.digest(Confirmation(target: previous.target, mode: previous.mode, operationID: id,
            versionString: snapshot.versionString, buildNumber: snapshot.buildNumber,
            contentDigest: snapshot.contentDigest, contentFingerprintVersion: 2, resubmission: binding))
        var record = ReleaseWorkflowRecord(operationID: id, target: previous.target, mode: previous.mode,
            versionString: snapshot.versionString, buildNumber: snapshot.buildNumber,
            contentDigest: snapshot.contentDigest, confirmationDigest: digest, preparedAt: now, updatedAt: now,
            state: .prepared, appleState: snapshot.appleState, submissionID: submissionID,
            submissionItemID: itemID, contentFingerprintVersion: 2, reviewItemIDs: snapshot.reviewItemIDs,
            resubmission: binding, submissionState: snapshot.submissionState)
        updateReviewStatus(&record, snapshot: snapshot)
        record.nextAction = "validateResubmission"
        try save(record)
        try write(Data(id.utf8), to: activeURL(previous.target))
        return record
    }

    func status(operationID: String, accountKey: String) async throws -> ReleaseWorkflowRecord {
        var record = try load(operationID)
        try checkAccount(accountKey, target: record.target)
        let lock = try acquire(record.target); defer { release(lock) }
        record = try load(operationID)
        let snapshot = try await api.snapshot(record.target)
        try snapshot.check(record.target, requirePreparedBuild: false)
        updateReviewStatus(&record, snapshot: snapshot)
        if record.submissionProgress == nil || (record.submissionID == nil && record.submissionProgress?.phase == .creatingSubmission) {
          if snapshot.submissionItemsComplete && ((record.state == .submissionPending && snapshot.submissionState != "COMPLETE") || snapshot.currentlySubmitted && Self.submittedStates.contains(ASCReleaseStatus.normalize(snapshot.appleState))) {
            record.submissionID = snapshot.submissionID ?? record.submissionID
            record.submissionItemID = snapshot.submissionItemID ?? record.submissionItemID
          }
        }
        record.resumableSubmissionID = nil
        record.requiresLegacyRecoveryConfirmation = nil
        record.resumableResubmissionID = nil
        if snapshot.currentlySubmitted && Self.submittedStates.contains(ASCReleaseStatus.normalize(snapshot.appleState)) {
            guard snapshot.attachedBuildID == record.target.buildID,
                  snapshot.versionString == record.versionString, snapshot.buildNumber == record.buildNumber else {
                throw ReleaseWorkflowError.identityChanged
            }
            guard isConfirmedSubmission(snapshot, record: record) else { throw ReleaseWorkflowError.uncertainOutcome }
            record.state = .submitted
            record.lastErrorCode = nil
            record.lastDiagnostic = nil
        } else if record.state == .submissionPending, canResumeResubmission(snapshot, record: record) {
            record.resumableResubmissionID = snapshot.submissionID
            record.lastErrorCode = "resubmission_requires_confirmation"
            record.nextAction = "confirmResubmissionContinuation"
        } else if record.state == .submissionPending, canResume(snapshot, record: record) {
            // This only advertises a verified draft. Resuming still needs the
            // exact draft ID plus explicit confirmation in a separate submit.
            record.resumableSubmissionID = snapshot.submissionID
            record.requiresLegacyRecoveryConfirmation = record.submissionProgress == nil ? true : nil
            record.lastErrorCode = "submission_draft_requires_confirmation"
        } else if (record.state == .releaseModePending && snapshot.releaseType == record.mode.rawValue) ||
                    (record.state == .attachmentPending && snapshot.attachedBuildID == record.target.buildID) {
            // The mode effect is now known. Changed content needs a new plan, not
            // an irreversible pending state: no submission request was sent yet.
            do {
                try checkUnchanged(snapshot, record: record)
                record.state = .prepared
                record.lastErrorCode = nil
            } catch {
                record.state = .needsPreparation
                record.lastErrorCode = "prepared_content_changed"
            }
        }
        // An editable version does NOT prove that a timed-out submission POST failed.
        record.updatedAt = Date()
        try save(record)
        return record
    }

    func validate(operationID: String, accountKey: String) async throws -> ReleaseWorkflowRecord {
        var record = try load(operationID)
        try checkAccount(accountKey, target: record.target)
        let lock = try acquire(record.target); defer { release(lock) }
        record = try requireActive(record)
        guard record.state == .prepared || record.state == .validated ||
                (record.state == .submissionPending && (record.resumableSubmissionID != nil || record.resumableResubmissionID != nil)) else { throw ReleaseWorkflowError.unsafeState }
        return try await validateLocked(record, allowingDraft: record.state == .submissionPending ? record.resumableSubmissionID : nil)
    }

    func submit(operationID: String, accountKey: String, confirmationDigest: String,
                resumeSubmissionID: String? = nil, confirmLegacyDraftRecovery: Bool = false) async throws -> ReleaseWorkflowRecord {
        var record = try load(operationID)
        try checkAccount(accountKey, target: record.target)
        let lock = try acquire(record.target); defer { release(lock) }
        record = try requireActive(record)
        guard record.confirmationDigest == confirmationDigest else { throw ReleaseWorkflowError.confirmationRequired }
        if record.state == .submitted {
            // Idempotency must not misrepresent a later rejection as a new submit.
            let snapshot = try await api.snapshot(record.target)
            try snapshot.check(record.target, requirePreparedBuild: false)
            if snapshot.currentlySubmitted && Self.submittedStates.contains(ASCReleaseStatus.normalize(snapshot.appleState)) {
                guard snapshot.attachedBuildID == record.target.buildID,
                      snapshot.versionString == record.versionString, snapshot.buildNumber == record.buildNumber else {
                    throw ReleaseWorkflowError.identityChanged
                }
                guard isConfirmedSubmission(snapshot, record: record) else { throw ReleaseWorkflowError.uncertainOutcome }
            }
            updateReviewStatus(&record, snapshot: snapshot)
            record.updatedAt = Date()
            try save(record)
            return record
        }
        guard record.resubmission == nil || !confirmLegacyDraftRecovery else {
            throw ReleaseWorkflowError.unsafeState
        }
        if let resumeSubmissionID {
            guard record.state == .submissionPending, ReleaseWorkflowTarget.validID(resumeSubmissionID) else { throw ReleaseWorkflowError.unsafeState }
            // Old journals cannot prove their final-request boundary. This extra
            // confirmation asserts independent evidence of a pre-PATCH abort;
            // a merely unknown historical outcome must not be retried.
            guard record.submissionProgress != nil || confirmLegacyDraftRecovery else { throw ReleaseWorkflowError.confirmationRequired }
            let candidate = try await api.snapshot(record.target)
            guard (record.resubmission == nil ? canResume(candidate, record: record) : canResumeResubmission(candidate, record: record)),
                  candidate.submissionID == resumeSubmissionID else {
                throw ReleaseWorkflowError.uncertainOutcome
            }
            record.submissionID = resumeSubmissionID
            record.submissionItemID = candidate.submissionItemID
            if !candidate.reviewItemIDs.isEmpty { record.reviewItemIDs = candidate.reviewItemIDs }
            record.resumableSubmissionID = resumeSubmissionID
            try save(record)
        }
        guard (record.state != .submissionPending || resumeSubmissionID != nil), record.state != .releaseModePending,
              record.state != .attachmentPending else { throw ReleaseWorkflowError.uncertainOutcome }
        guard record.state == .validated || resumeSubmissionID != nil else { throw ReleaseWorkflowError.notReady }
        record = try await validateLocked(record, allowingDraft: resumeSubmissionID)
        guard record.validation?.ready == true else { throw ReleaseWorkflowError.notReady }

        var snapshot = try await api.snapshot(record.target)
        try checkUnchanged(snapshot, record: record, allowingDraft: resumeSubmissionID)
        if snapshot.releaseType != record.mode.rawValue {
            record.state = .releaseModePending
            record.submissionProgress = .init(phase: .settingReleaseMode)
            record.updatedAt = Date()
            try save(record) // Intent must be durable before the first mutation.
            do {
                try await api.setReleaseMode(record.mode, target: record.target)
                snapshot = try await api.snapshot(record.target)
                try checkUnchanged(snapshot, record: record)
                guard snapshot.releaseType == record.mode.rawValue else { throw ReleaseWorkflowError.uncertainOutcome }
            } catch {
                let diagnostic = ReleaseSubmissionDiagnostic.make(error, phase: .settingReleaseMode)
                record.lastDiagnostic = diagnostic
                record.lastErrorCode = diagnostic.category
                record.updatedAt = Date()
                try save(record)
                throw ReleaseWorkflowError.submissionFailed(diagnostic)
            }
            record.state = .validated
            record.lastDiagnostic = nil
            try save(record)
        }
        record.state = .submissionPending
        record.submissionProgress = (record.resubmission?.submissionID ?? resumeSubmissionID).map {
            .init(phase: .verifyingContent, submissionID: $0, submissionItemID: record.submissionItemID)
        } ?? .init(phase: .checkingExisting)
        record.resumableSubmissionID = nil
        record.resumableResubmissionID = nil
        record.requiresLegacyRecoveryConfirmation = nil
        record.lastDiagnostic = nil
        record.updatedAt = Date()
        try save(record) // Never replay this boundary, even after a crash or lost reply.
        do {
            let submissionID: String?
            if let binding = record.resubmission {
                submissionID = try await api.resubmit(record.target, binding: binding,
                    expectedContentDigest: record.contentDigest, expectedFingerprintVersion: record.contentFingerprintVersion,
                    expectedReleaseMode: record.mode) { progress in
                    try await self.persistSubmissionProgress(operationID: operationID, progress: progress)
                }
            } else {
                submissionID = try await api.submit(record.target, expectedContentDigest: record.contentDigest,
                    expectedFingerprintVersion: record.contentFingerprintVersion,
                    expectedReleaseMode: record.mode, resumingSubmissionID: resumeSubmissionID) { progress in
                    try await self.persistSubmissionProgress(operationID: operationID, progress: progress)
                }
            }
            record = try load(operationID)
            record.submissionID = submissionID ?? record.submissionID
            try save(record)
            let after = try await api.snapshot(record.target)
            try after.check(record.target)
            guard after.versionString == record.versionString, after.buildNumber == record.buildNumber else {
                throw ReleaseWorkflowError.identityChanged
            }
            updateReviewStatus(&record, snapshot: after)
            if after.currentlySubmitted && Self.submittedStates.contains(ASCReleaseStatus.normalize(after.appleState)) && isConfirmedSubmission(after, record: record) {
                record.state = .submitted
            }
            record.updatedAt = Date()
            try save(record)
            return record
        } catch {
            // Do not store raw Apple/CLI bodies, cookies or demo credentials.
            record = try load(operationID)
            let diagnostic = ReleaseSubmissionDiagnostic.make(error, phase: record.submissionProgress?.phase)
            record.lastDiagnostic = diagnostic
            record.lastErrorCode = record.submissionProgress?.phase == .acknowledged ? "submission_accepted_status_unverified" : "submission_outcome_unknown"
            record.updatedAt = Date()
            try save(record)
            throw ReleaseWorkflowError.submissionFailed(diagnostic)
        }
    }

    private func persistSubmissionProgress(operationID: String, progress: ReleaseSubmissionProgress) throws {
        var record = try load(operationID)
        guard record.state == .submissionPending,
              progress.submissionID.map(ReleaseWorkflowTarget.validID) ?? true,
              progress.submissionItemID.map(ReleaseWorkflowTarget.validID) ?? true,
              progress.reviewItemID.map(ReleaseWorkflowTarget.validID) ?? true,
              record.submissionID == nil || progress.submissionID == record.submissionID,
              record.submissionItemID == nil || progress.submissionItemID == nil || record.submissionItemID == progress.submissionItemID else {
            throw ReleaseWorkflowError.unsafeState
        }
        if progress.phase == .resolvingReviewItem || progress.phase == .reviewItemResolved {
            guard let id = progress.resolvedItemID, record.resubmission?.itemIDsToResolve?.contains(id) == true,
                  ReleaseWorkflowTarget.validID(id) else { throw ReleaseWorkflowError.unsafeState }
        } else if progress.resolvedItemID != nil { throw ReleaseWorkflowError.unsafeState }
        if progress.phase == .addingReviewItem || progress.phase == .reviewItemAdded {
            guard let item = progress.reviewItem, record.target.reviewItems.contains(item),
                  progress.submissionID != nil,
                  (progress.phase == .addingReviewItem && progress.reviewItemID == nil) ||
                    (progress.phase == .reviewItemAdded && progress.reviewItemID != nil) else {
                throw ReleaseWorkflowError.unsafeState
            }
            if let itemID = progress.reviewItemID {
                var itemIDs = record.reviewItemIDs ?? [:]
                guard itemIDs[item.key] == nil || itemIDs[item.key] == itemID,
                      !itemIDs.contains(where: { $0.key != item.key && $0.value == itemID }),
                      itemID != record.submissionItemID else { throw ReleaseWorkflowError.unsafeState }
                itemIDs[item.key] = itemID
                record.reviewItemIDs = itemIDs
            }
        } else if progress.reviewItem != nil || progress.reviewItemID != nil {
            throw ReleaseWorkflowError.unsafeState
        }
        record.submissionProgress = progress
        record.submissionID = progress.submissionID ?? record.submissionID
        record.submissionItemID = progress.submissionItemID ?? record.submissionItemID
        record.updatedAt = Date()
        try save(record)
    }

    private func validateLocked(_ input: ReleaseWorkflowRecord, allowingDraft: String? = nil) async throws -> ReleaseWorkflowRecord {
        var record = input
        do {
            let before = try await api.snapshot(record.target)
            try checkUnchanged(before, record: record, allowingDraft: allowingDraft)
            let validation = try await api.readiness(record.target, resubmission: record.resubmission)
            let after = try await api.snapshot(record.target)
            try checkUnchanged(after, record: record, allowingDraft: allowingDraft)
            record.validation = validation
            record.state = input.state == .submissionPending ? .submissionPending : (validation.ready ? .validated : .prepared)
            record.lastErrorCode = validation.ready ? nil : "readiness_blocked"
            updateReviewStatus(&record, snapshot: after)
            if record.resubmission != nil { record.nextAction = validation.ready ? "confirmResubmission" : "completeReadinessChecks" }
            record.updatedAt = Date()
            try save(record)
            return record
        } catch {
            if input.state == .submissionPending { record.state = .submissionPending; record.resumableSubmissionID = nil }
            else if case ReleaseWorkflowError.contentChanged = error { record.state = .needsPreparation }
            else { record.state = .prepared }
            record.validation = nil
            record.lastErrorCode = "preflight_failed"
            record.updatedAt = Date()
            try save(record)
            throw error
        }
    }

    private func canResumeResubmission(_ snapshot: ReleaseWorkflowSnapshot, record: ReleaseWorkflowRecord) -> Bool {
        guard record.state == .submissionPending, let binding = record.resubmission, binding.matches(snapshot),
              let progress = record.submissionProgress else { return false }
        switch progress.phase {
        case .verifyingContent, .reviewItemResolved: break
        case .resolvingReviewItem:
            // A read proves the resolution took effect; an unresolved item after
            // timeout does not prove the write failed and may not be retried.
            guard let id = progress.resolvedItemID, snapshot.submissionItemStates[id] == "READY_FOR_REVIEW" else { return false }
        default: return false
        }
        return (try? checkUnchanged(snapshot, record: record)) != nil
    }

    private func canResume(_ snapshot: ReleaseWorkflowSnapshot, record: ReleaseWorkflowRecord) -> Bool {
        // Legacy journals have no phase; an explicit ID confirmation can recover
        // their unique unchanged draft. A known final PATCH intent is never replayed.
        guard record.resubmission == nil,
              let id = snapshot.submissionID, snapshot.canResumeSubmission,
              snapshot.releaseType == record.mode.rawValue,
              knownSubmissionItemsMatch(snapshot, record: record) else { return false }
        if !snapshot.submissionItemsComplete {
            // An empty or partial draft cannot identify its owner. Only a saved
            // successful create response proves that this operation owns it.
            guard record.submissionID == id, record.submissionProgress != nil else { return false }
        }
        if let progress = record.submissionProgress {
            switch progress.phase {
            case .creatingSubmission: break // The create reply may have been lost.
            case .submissionCreated, .versionAdded, .reviewItemAdded, .verifyingContent:
                guard record.submissionID != nil else { return false }
            case .addingVersion:
                guard record.submissionID != nil,
                      snapshot.submissionItemID != nil || lastWriteWasRejected(record) else { return false }
            case .addingReviewItem:
                guard record.submissionID != nil, let item = progress.reviewItem,
                      snapshot.reviewItemIDs[item.key] != nil || lastWriteWasRejected(record) else { return false }
            case .settingReleaseMode, .checkingExisting, .submitting, .acknowledged, .resolvingReviewItem, .reviewItemResolved: return false
            }
            guard record.submissionID == nil || record.submissionID == id,
                  record.submissionItemID == nil || record.submissionItemID == snapshot.submissionItemID else { return false }
        }
        do { try checkUnchanged(snapshot, record: record, allowingDraft: id); return true }
        catch { return false }
    }

    private func isConfirmedSubmission(_ snapshot: ReleaseWorkflowSnapshot, record: ReleaseWorkflowRecord) -> Bool {
        guard let id = record.submissionID, snapshot.submissionID == id,
              snapshot.submissionItemsComplete,
              record.target.reviewItems.isEmpty || snapshot.submissionItemID != nil,
              Set(snapshot.reviewItemIDs.keys) == Set(record.target.reviewItems.map(\.key)),
              knownSubmissionItemsMatch(snapshot, record: record),
              ["WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES", "COMPLETING", "COMPLETE"].contains(snapshot.submissionState ?? ""),
              record.submissionItemID == nil || snapshot.submissionItemID == record.submissionItemID else { return false }
        return true
    }

    private func lastWriteWasRejected(_ record: ReleaseWorkflowRecord) -> Bool {
        guard let diagnostic = record.lastDiagnostic, diagnostic.phase == record.submissionProgress?.phase,
              diagnostic.category == "apple_request_rejected", let status = diagnostic.apple?.httpStatus else { return false }
        // A timeout status is still an uncertain effect, even when represented
        // as an HTTP client error. Missing items alone never prove failure.
        return (400..<500).contains(status) && status != 408
    }

    private func knownSubmissionItemsMatch(_ snapshot: ReleaseWorkflowSnapshot, record: ReleaseWorkflowRecord) -> Bool {
        let expected = Set(record.target.reviewItems.map(\.key))
        guard Set(snapshot.reviewItemIDs.keys).isSubset(of: expected),
              snapshot.reviewItemIDs.values.allSatisfy(ReleaseWorkflowTarget.validID),
              Set(snapshot.reviewItemIDs.values).count == snapshot.reviewItemIDs.count,
              !snapshot.reviewItemIDs.values.contains(where: { $0 == snapshot.submissionItemID }),
              record.submissionItemID == nil || record.submissionItemID == snapshot.submissionItemID,
              (record.reviewItemIDs ?? [:]).allSatisfy({ snapshot.reviewItemIDs[$0.key] == $0.value }) else { return false }
        return true
    }

    private func checkUnchanged(_ snapshot: ReleaseWorkflowSnapshot, record: ReleaseWorkflowRecord, allowingDraft: String? = nil) throws {
        try snapshot.check(record.target)
        let ownResubmission = record.resubmission.map { binding in
            binding.matches(snapshot) && snapshot.releaseType == record.mode.rawValue
        } ?? false
        if record.resubmission != nil && !ownResubmission { throw ReleaseWorkflowError.uncertainOutcome }
        let ownDraft = ownResubmission || (allowingDraft != nil && snapshot.submissionID == allowingDraft && snapshot.canResumeSubmission &&
            snapshot.releaseType == record.mode.rawValue)
        guard (ASCReleaseStatus.isEditable(snapshot.appleState) || (ownDraft && ["READY_FOR_REVIEW", "ACCEPTED"].contains(ASCReleaseStatus.normalize(snapshot.appleState)))), snapshot.versionString == record.versionString,
              snapshot.buildNumber == record.buildNumber, snapshot.matchesContentDigest(record.contentDigest, fingerprintVersion: record.contentFingerprintVersion) else {
            throw ReleaseWorkflowError.contentChanged
        }
        guard !snapshot.hasSubmissionConflict || ownDraft else { throw ReleaseWorkflowError.uncertainOutcome }
        if ownDraft && !knownSubmissionItemsMatch(snapshot, record: record) { throw ReleaseWorkflowError.uncertainOutcome }
    }

    private func canPrepareResubmission(_ snapshot: ReleaseWorkflowSnapshot, record: ReleaseWorkflowRecord, resolveRejectedItems: Bool = false) -> Bool {
        record.state == .submitted && record.submissionProgress?.phase == .acknowledged &&
            (snapshot.canResubmitSubmission || (resolveRejectedItems && snapshot.canResolveSubmission)) && snapshot.submissionID == record.submissionID &&
            snapshot.submissionItemID != nil && snapshot.submissionItemID == record.submissionItemID &&
            snapshot.reviewItemIDs == (record.reviewItemIDs ?? [:]) &&
            snapshot.submissionItemsComplete && snapshot.reviewProductsReady &&
            snapshot.attachedBuildID == record.target.buildID && snapshot.buildValid &&
            snapshot.versionString == record.versionString && snapshot.buildNumber == record.buildNumber &&
            snapshot.releaseType == record.mode.rawValue && knownSubmissionItemsMatch(snapshot, record: record) &&
            Set(snapshot.reviewItemIDs.keys) == Set(record.target.reviewItems.map(\.key))
    }

    private func updateReviewStatus(_ record: inout ReleaseWorkflowRecord, snapshot: ReleaseWorkflowSnapshot) {
        record.appleState = snapshot.appleState
        record.submissionState = snapshot.submissionState
        record.submissionItemStates = snapshot.submissionItemStates
        record.resolvableSubmissionID = snapshot.canResolveSubmission && canPrepareResubmission(snapshot, record: record, resolveRejectedItems: true) ? snapshot.submissionID : nil
        record.reviewOutcome = snapshot.submissionState == "UNRESOLVED_ISSUES" ? "issuesUnresolved" : (snapshot.currentlySubmitted ? "submitted" : "notSubmitted")
        record.nextAction = record.resolvableSubmissionID != nil ? "resolveReviewIssues" : (snapshot.currentlySubmitted ? "waitForApple" : "inspectReviewStatus")
        record.resubmittableSubmissionID = canPrepareResubmission(snapshot, record: record) ? snapshot.submissionID : nil
        if record.resubmittableSubmissionID != nil { record.lastErrorCode = "resubmission_requires_preparation"; record.nextAction = "prepareResubmission" }
        else if record.state == .submitted && snapshot.submissionState == "UNRESOLVED_ISSUES" {
            record.lastErrorCode = "review_issues_require_resolution"
        }
    }

    private func checkAccount(_ account: String, target: ReleaseWorkflowTarget) throws {
        guard account == target.accountKey, api.accountKey == target.accountKey else { throw ReleaseWorkflowError.accountChanged }
    }

    private func requireActive(_ record: ReleaseWorkflowRecord) throws -> ReleaseWorkflowRecord {
        guard try activeRecord(record.target)?.operationID == record.operationID else { throw ReleaseWorkflowError.unsafeState }
        return try load(record.operationID)
    }

    private static let submittedStates = ReleaseWorkflowSnapshot.submittedAppleStates

    private struct Confirmation: Encodable {
        let target: ReleaseWorkflowTarget
        let mode: ReleaseWorkflowMode
        let operationID: String
        let versionString: String
        let buildNumber: String
        let contentDigest: String
        var contentFingerprintVersion: Int? = nil
        var resubmission: ReleaseResubmissionBinding? = nil
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    private func scope(_ target: ReleaseWorkflowTarget) -> String {
        SHA256.hash(data: Data("\(target.accountKey)|\(target.appID)|\(target.platform)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func activeURL(_ target: ReleaseWorkflowTarget) -> URL { directory.appendingPathComponent("active-\(scope(target)).txt") }

    private func activeRecord(_ target: ReleaseWorkflowTarget) throws -> ReleaseWorkflowRecord? {
        let url = activeURL(target)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try rejectSymlink(url)
        let id = try String(contentsOf: url, encoding: .utf8)
        return try load(id)
    }

    private func load(_ id: String) throws -> ReleaseWorkflowRecord {
        guard UUID(uuidString: id) != nil else { throw ReleaseWorkflowError.unknownOperation }
        let url = directory.appendingPathComponent("\(id.lowercased()).json")
        try rejectSymlink(url)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReleaseWorkflowError.unknownOperation }
        let record = try JSONDecoder().decode(ReleaseWorkflowRecord.self, from: Data(contentsOf: url))
        guard record.operationID == id.lowercased() else { throw ReleaseWorkflowError.unsafeState }
        try record.target.validate()
        let itemIDs = record.reviewItemIDs ?? [:]
        guard Set(itemIDs.keys).isSubset(of: Set(record.target.reviewItems.map(\.key))),
              itemIDs.values.allSatisfy(ReleaseWorkflowTarget.validID),
              Set(itemIDs.values).count == itemIDs.count,
              !itemIDs.values.contains(where: { $0 == record.submissionItemID }) else { throw ReleaseWorkflowError.unsafeState }
        if let binding = record.resubmission {
            guard UUID(uuidString: binding.previousOperationID) != nil, binding.previousOperationID != record.operationID,
                  ReleaseWorkflowTarget.validID(binding.submissionID), ReleaseWorkflowTarget.validID(binding.submissionItemID),
                  record.submissionID == binding.submissionID, record.submissionItemID == binding.submissionItemID,
                  itemIDs == binding.reviewItemIDs,
                  Set(itemIDs.keys) == Set(record.target.reviewItems.map(\.key)),
                  binding.itemIDsToResolve.map({ Set($0).count == $0.count && Set($0).isSubset(of: Set([binding.submissionItemID] + Array(binding.reviewItemIDs.values))) && $0.allSatisfy { binding.itemStates?[$0] == "REJECTED" } }) ?? true,
                  binding.itemStates.map({ Set($0.keys) == Set([binding.submissionItemID] + Array(binding.reviewItemIDs.values)) }) ?? true else { throw ReleaseWorkflowError.unsafeState }
        }
        guard record.contentFingerprintVersion == nil || record.contentFingerprintVersion == 2 else { throw ReleaseWorkflowError.unsafeState }
        let expected = try Self.digest(Confirmation(target: record.target, mode: record.mode, operationID: record.operationID,
            versionString: record.versionString, buildNumber: record.buildNumber, contentDigest: record.contentDigest,
            contentFingerprintVersion: record.contentFingerprintVersion, resubmission: record.resubmission))
        guard expected == record.confirmationDigest else { throw ReleaseWorkflowError.unsafeState }
        return record
    }

    private func save(_ record: ReleaseWorkflowRecord) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(record), to: directory.appendingPathComponent("\(record.operationID).json"))
    }

    private func write(_ data: Data, to url: URL) throws {
        try rejectSymlink(url)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ReleaseWorkflowError.storage }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw ReleaseWorkflowError.storage }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        guard parent >= 0 else { throw ReleaseWorkflowError.storage }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw ReleaseWorkflowError.storage }
    }

    private func rejectSymlink(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw ReleaseWorkflowError.storage }
    }

    private func acquire(_ target: ReleaseWorkflowTarget) throws -> Int32 {
        try rejectSymlink(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("lock-\(scope(target))").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ReleaseWorkflowError.storage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw ReleaseWorkflowError.busy }
        return fd
    }

    private func release(_ fd: Int32) { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
}
