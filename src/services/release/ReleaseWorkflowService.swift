import CryptoKit
import Darwin
import Foundation

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

    init(projectID: String, projectPath: String, appID: String, bundleID: String, platform: String,
         accountKey: String, versionID: String, buildID: String, releaseTargetID: String? = nil) {
        self.projectID = projectID; self.projectPath = projectPath
        self.appID = appID; self.bundleID = bundleID; self.platform = platform
        self.accountKey = accountKey; self.versionID = versionID; self.buildID = buildID
        self.releaseTargetID = releaseTargetID
    }
    enum CodingKeys: String, CodingKey {
        case projectID = "projectId", projectPath, appID = "appId", bundleID = "bundleId", platform, accountKey
        case versionID = "versionId", buildID = "buildId", releaseTargetID = "releaseTargetId"
    }

    func validate() throws {
        guard !projectID.isEmpty, !bundleID.isEmpty, !accountKey.isEmpty,
              releaseTargetID.map(Self.validID) ?? true,
              ["IOS", "MAC_OS", "TV_OS", "VISION_OS"].contains(platform),
              [appID, versionID, buildID].allSatisfy(Self.validID),
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
    func setReleaseMode(_ mode: ReleaseWorkflowMode, target: ReleaseWorkflowTarget) async throws
    func submit(_ target: ReleaseWorkflowTarget, expectedContentDigest: String,
                expectedFingerprintVersion: Int?, expectedReleaseMode: ReleaseWorkflowMode, resumingSubmissionID: String?,
                progress: @escaping @Sendable (ReleaseSubmissionProgress) async throws -> Void) async throws -> String?
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
    enum CodingKeys: String, CodingKey {
        case operationID = "operationId", target, mode, versionString, buildNumber, contentDigest, confirmationDigest
        case preparedAt, updatedAt, state, validation, lastErrorCode, appleState, submissionID = "submissionId"
        case submissionProgress, lastDiagnostic
        case resumableSubmissionID = "resumableSubmissionId"
        case submissionItemID = "submissionItemId"
        case contentFingerprintVersion
        case requiresLegacyRecoveryConfirmation
    }
}

enum ReleaseWorkflowError: Error, LocalizedError {
    case invalidTarget, accountChanged, identityChanged, contentChanged, buildNotPrepared
    case unknownOperation, busy, unsafeState, confirmationRequired, notReady, uncertainOutcome, storage
    case submissionFailed(ReleaseSubmissionDiagnostic)
    var errorDescription: String? {
        switch self {
        case .invalidTarget: return "Der Release-Auftrag benötigt eindeutige Projekt-, Konto-, App-, Plattform-, Versions- und Build-IDs."
        case .accountChanged: return "Der Release-Auftrag gehört zu einem anderen Apple-Konto."
        case .identityChanged: return "App, Plattform, Version oder zugeordneter Build stimmen nicht mit dem Release-Auftrag überein."
        case .contentChanged: return "Texte, Medien oder Release-Daten haben sich geändert. Bitte erneut vorbereiten und prüfen."
        case .buildNotPrepared: return "Zuerst die genaue Version mit einem verarbeiteten, passenden Build vorbereiten und verknüpfen."
        case .unknownOperation: return "Der Release-Auftrag wurde nicht gefunden."
        case .busy: return "Für diese App und Plattform läuft bereits ein Release-Schritt."
        case .unsafeState: return "Der gespeicherte Release-Zustand ist ungültig oder nicht mehr aktiv."
        case .confirmationRequired: return "Der Bestätigungswert muss genau dem geprüften Release-Auftrag entsprechen."
        case .notReady: return "Die frische Release-Prüfung hat offene oder nicht verifizierte Punkte gefunden."
        case .uncertainOutcome: return "Ein vorheriger Schreibauftrag hat einen unklaren Ausgang. Nur den Status abgleichen; nicht erneut einreichen."
        case .submissionFailed(let diagnostic): return diagnostic.message
        case .storage: return "Der private Release-Zustand konnte nicht sicher gespeichert werden."
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

    func prepare(target: ReleaseWorkflowTarget, mode: ReleaseWorkflowMode) async throws -> ReleaseWorkflowRecord {
        try await prepareInternal(target: target, mode: mode, attach: nil)
    }

    /// Explicit UI action only. MCP/CLI `release_prepare` never attaches a build.
    /// The existing manager supplies its checked attachment operation; the same
    /// process lock and durable intent cover it before final preparation begins.
    func prepareAfterAttachingBuild(target: ReleaseWorkflowTarget, mode: ReleaseWorkflowMode,
                                   attach: @escaping () async throws -> Void) async throws -> ReleaseWorkflowRecord {
        try await prepareInternal(target: target, mode: mode, attach: attach)
    }

    private func prepareInternal(target: ReleaseWorkflowTarget, mode: ReleaseWorkflowMode,
                                 attach: (() async throws -> Void)?) async throws -> ReleaseWorkflowRecord {
        try target.validate()
        try checkAccount(target.accountKey, target: target)
        let lock = try acquire(target); defer { release(lock) }
        let previous = try activeRecord(target)
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

    func status(operationID: String, accountKey: String) async throws -> ReleaseWorkflowRecord {
        var record = try load(operationID)
        try checkAccount(accountKey, target: record.target)
        let lock = try acquire(record.target); defer { release(lock) }
        record = try load(operationID)
        let snapshot = try await api.snapshot(record.target)
        try snapshot.check(record.target, requirePreparedBuild: false)
        record.appleState = snapshot.appleState
        if record.submissionProgress == nil || (record.submissionID == nil && record.submissionProgress?.phase == .creatingSubmission) {
          if (record.state == .submissionPending && snapshot.submissionState != "COMPLETE") || Self.submittedStates.contains(ASCReleaseStatus.normalize(snapshot.appleState)) {
            record.submissionID = snapshot.submissionID ?? record.submissionID
            record.submissionItemID = snapshot.submissionItemID ?? record.submissionItemID
          }
        }
        record.resumableSubmissionID = nil
        record.requiresLegacyRecoveryConfirmation = nil
        if Self.submittedStates.contains(ASCReleaseStatus.normalize(snapshot.appleState)) {
            guard snapshot.attachedBuildID == record.target.buildID,
                  snapshot.versionString == record.versionString, snapshot.buildNumber == record.buildNumber else {
                throw ReleaseWorkflowError.identityChanged
            }
            guard isConfirmedSubmission(snapshot, record: record) else { throw ReleaseWorkflowError.uncertainOutcome }
            record.state = .submitted
            record.lastErrorCode = nil
            record.lastDiagnostic = nil
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
                (record.state == .submissionPending && record.resumableSubmissionID != nil) else { throw ReleaseWorkflowError.unsafeState }
        return try await validateLocked(record, allowingDraft: record.state == .submissionPending ? record.resumableSubmissionID : nil)
    }

    func submit(operationID: String, accountKey: String, confirmationDigest: String,
                resumeSubmissionID: String? = nil, confirmLegacyDraftRecovery: Bool = false) async throws -> ReleaseWorkflowRecord {
        var record = try load(operationID)
        try checkAccount(accountKey, target: record.target)
        let lock = try acquire(record.target); defer { release(lock) }
        record = try requireActive(record)
        guard record.confirmationDigest == confirmationDigest else { throw ReleaseWorkflowError.confirmationRequired }
        if record.state == .submitted { return record }
        if let resumeSubmissionID {
            guard record.state == .submissionPending, ReleaseWorkflowTarget.validID(resumeSubmissionID) else { throw ReleaseWorkflowError.unsafeState }
            // Old journals cannot prove their final-request boundary. This extra
            // confirmation asserts independent evidence of a pre-PATCH abort;
            // a merely unknown historical outcome must not be retried.
            guard record.submissionProgress != nil || confirmLegacyDraftRecovery else { throw ReleaseWorkflowError.confirmationRequired }
            let candidate = try await api.snapshot(record.target)
            guard canResume(candidate, record: record), candidate.submissionID == resumeSubmissionID else {
                throw ReleaseWorkflowError.uncertainOutcome
            }
            record.submissionID = resumeSubmissionID
            record.submissionItemID = candidate.submissionItemID
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
        record.submissionProgress = resumeSubmissionID.map {
            .init(phase: .verifyingContent, submissionID: $0, submissionItemID: record.submissionItemID)
        } ?? .init(phase: .checkingExisting)
        record.resumableSubmissionID = nil
        record.requiresLegacyRecoveryConfirmation = nil
        record.lastDiagnostic = nil
        record.updatedAt = Date()
        try save(record) // Never replay this boundary, even after a crash or lost reply.
        do {
            let submissionID = try await api.submit(record.target, expectedContentDigest: record.contentDigest,
                                                     expectedFingerprintVersion: record.contentFingerprintVersion,
                                                     expectedReleaseMode: record.mode, resumingSubmissionID: resumeSubmissionID) { progress in
                try await self.persistSubmissionProgress(operationID: operationID, progress: progress)
            }
            record = try load(operationID)
            record.submissionID = submissionID ?? record.submissionID
            try save(record)
            let after = try await api.snapshot(record.target)
            try after.check(record.target)
            guard after.versionString == record.versionString, after.buildNumber == record.buildNumber else {
                throw ReleaseWorkflowError.identityChanged
            }
            record.appleState = after.appleState
            if Self.submittedStates.contains(ASCReleaseStatus.normalize(after.appleState)) && isConfirmedSubmission(after, record: record) {
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
              record.submissionID == nil || progress.submissionID == record.submissionID else {
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
            let validation = try await api.readiness(record.target)
            let after = try await api.snapshot(record.target)
            try checkUnchanged(after, record: record, allowingDraft: allowingDraft)
            record.validation = validation
            record.state = input.state == .submissionPending ? .submissionPending : (validation.ready ? .validated : .prepared)
            record.lastErrorCode = validation.ready ? nil : "readiness_blocked"
            record.appleState = after.appleState
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

    private func canResume(_ snapshot: ReleaseWorkflowSnapshot, record: ReleaseWorkflowRecord) -> Bool {
        // Legacy journals have no phase; an explicit ID confirmation can recover
        // their unique unchanged draft. A known final PATCH intent is never replayed.
        guard let id = snapshot.submissionID, snapshot.canResumeSubmission,
              snapshot.releaseType == record.mode.rawValue else { return false }
        if let progress = record.submissionProgress {
            switch progress.phase {
            case .creatingSubmission: break // The create reply may have been lost.
            case .submissionCreated, .addingVersion, .versionAdded, .verifyingContent:
                guard record.submissionID != nil else { return false }
            case .settingReleaseMode, .checkingExisting, .submitting, .acknowledged: return false
            }
            guard record.submissionID == nil || record.submissionID == id,
                  record.submissionItemID == nil || record.submissionItemID == snapshot.submissionItemID else { return false }
        }
        do { try checkUnchanged(snapshot, record: record, allowingDraft: id); return true }
        catch { return false }
    }

    private func isConfirmedSubmission(_ snapshot: ReleaseWorkflowSnapshot, record: ReleaseWorkflowRecord) -> Bool {
        guard let id = record.submissionID, snapshot.submissionID == id,
              ["WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES", "COMPLETING", "COMPLETE"].contains(snapshot.submissionState ?? ""),
              record.submissionItemID == nil || snapshot.submissionItemID == record.submissionItemID else { return false }
        return true
    }

    private func checkUnchanged(_ snapshot: ReleaseWorkflowSnapshot, record: ReleaseWorkflowRecord, allowingDraft: String? = nil) throws {
        try snapshot.check(record.target)
        let ownDraft = allowingDraft != nil && snapshot.submissionID == allowingDraft && snapshot.canResumeSubmission &&
            snapshot.releaseType == record.mode.rawValue
        guard (ASCReleaseStatus.isEditable(snapshot.appleState) || (ownDraft && ASCReleaseStatus.normalize(snapshot.appleState) == "READY_FOR_REVIEW")), snapshot.versionString == record.versionString,
              snapshot.buildNumber == record.buildNumber, snapshot.matchesContentDigest(record.contentDigest, fingerprintVersion: record.contentFingerprintVersion) else {
            throw ReleaseWorkflowError.contentChanged
        }
        guard !snapshot.hasSubmissionConflict || ownDraft else { throw ReleaseWorkflowError.uncertainOutcome }
    }

    private func checkAccount(_ account: String, target: ReleaseWorkflowTarget) throws {
        guard account == target.accountKey, api.accountKey == target.accountKey else { throw ReleaseWorkflowError.accountChanged }
    }

    private func requireActive(_ record: ReleaseWorkflowRecord) throws -> ReleaseWorkflowRecord {
        guard try activeRecord(record.target)?.operationID == record.operationID else { throw ReleaseWorkflowError.unsafeState }
        return try load(record.operationID)
    }

    private static let submittedStates: Set<String> = ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE",
        "PENDING_APPLE_RELEASE", "PROCESSING_FOR_APP_STORE", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "ACCEPTED"]

    private struct Confirmation: Encodable {
        let target: ReleaseWorkflowTarget
        let mode: ReleaseWorkflowMode
        let operationID: String
        let versionString: String
        let buildNumber: String
        let contentDigest: String
        var contentFingerprintVersion: Int? = nil
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
        guard record.contentFingerprintVersion == nil || record.contentFingerprintVersion == 2 else { throw ReleaseWorkflowError.unsafeState }
        let expected = try Self.digest(Confirmation(target: record.target, mode: record.mode, operationID: record.operationID,
            versionString: record.versionString, buildNumber: record.buildNumber, contentDigest: record.contentDigest,
            contentFingerprintVersion: record.contentFingerprintVersion))
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
