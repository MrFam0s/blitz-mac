import Foundation

protocol ASCWriteStateService {
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion]
    func fetchAppInfoRecord(id: String) async throws -> ASCAppInfo
}
extension AppStoreConnectService: ASCWriteStateService {}

/// These are API-resource rules, not a blanket lock on every tab of a live app.
enum ASCEditability {
    static let appInfoFields: Set<String> = ["title", "name", "subtitle", "privacyPolicyUrl", "privacyChoicesUrl", "primaryCategory", "secondaryCategory", "ageRating"]
    static let versionFields: Set<String> = ["description", "keywords", "whatsNew", "supportUrl", "marketingUrl", "screenshots", "contentRightsDeclaration"]
    static let anytimeVersionFields: Set<String> = ["promotionalText", "copyright", "reviewContact"]

    static func allows(_ field: String, version: ASCAppStoreVersion?, appInfo: ASCAppInfo?) -> Bool {
        if appInfoFields.contains(field) { return ASCReleaseStatus.isEditable(appInfo?.attributes?.appStoreState) }
        if versionFields.contains(field) { return ASCReleaseStatus.isEditable(version?.attributes.appStoreState) }
        if anytimeVersionFields.contains(field) { return version != nil }
        return false
    }

    static func canEditProductReview(_ state: String?) -> Bool {
        ["MISSING_METADATA", "READY_TO_SUBMIT", "PREPARE_FOR_SUBMISSION", "REJECTED", "DEVELOPER_REJECTED", "DEVELOPER_ACTION_NEEDED"].contains(ASCReleaseStatus.normalize(state))
    }

    static func canEditProductLocalization(_ state: String?) -> Bool {
        canEditProductReview(state) || ["APPROVED", "DEVELOPER_REMOVED_FROM_SALE", "REMOVED_FROM_SALE"].contains(ASCReleaseStatus.normalize(state))
    }

    static func validateProductChanges(state: String?, oldReviewNote: String?, reviewNote: String?, changesLocalization: Bool) throws {
        if let reviewNote, reviewNote != (oldReviewNote ?? ""), !canEditProductReview(state) {
            throw ASCError.notFound("Review-Unterlagen dieses Produkts sind bei Apple gesperrt. Änderungen sind vor der Einreichung oder nach einer Ablehnung möglich.")
        }
        if changesLocalization && !canEditProductLocalization(state) {
            throw ASCError.notFound("Die Produktlokalisierung ist während der Prüfung bei Apple gesperrt.")
        }
    }

    static func preferredAppInfo(_ values: [ASCAppInfo]) -> ASCAppInfo? {
        values.first { ASCReleaseStatus.isEditable($0.attributes?.appStoreState) }
            ?? values.first { ASCReleaseStatus.isLive($0.attributes?.appStoreState) }
            ?? values.first
    }
}

struct ASCWriteTarget {
    let revision: UUID
    let appID: String
    let versionID: String?
    let appInfoID: String?
}

extension ASCManager {
    func canEditField(_ field: String) -> Bool {
        ASCEditability.allows(field, version: selectedVersion, appInfo: appInfo)
    }

    var screenshotEditingMessage: String {
        "Screenshots dieser Version sind bei Apple gesperrt. Wähle eine bearbeitbare Version oder wähle in der Übersicht „Versionsentwurf anlegen“."
    }

    func editingBlockedMessage(_ field: String) -> String {
        if field == "screenshots" { return screenshotEditingMessage }
        return "Dieses Feld ist für den aktuellen Apple-Status schreibgeschützt. Bitte aktualisiere den Status oder bearbeite eine neue Version."
    }

    func checkWriteTarget(_ target: ASCWriteTarget) throws {
        guard !Task.isCancelled, projectRevision == target.revision, app?.id == target.appID,
              selectedVersion?.id == target.versionID, appInfo?.id == target.appInfoID else {
            throw CancellationError()
        }
    }

    /// Called by manager entry points as well as UI: MCP callers receive the same protection.
    func validateWrite(fields: Set<String>, using service: any ASCWriteStateService) async throws -> ASCWriteTarget {
        guard let appID = app?.id else { throw ASCError.notFound("Keine App ausgewählt.") }
        for field in fields where !canEditField(field) { throw ASCError.notFound(editingBlockedMessage(field)) }
        let target = ASCWriteTarget(revision: projectRevision, appID: appID, versionID: selectedVersion?.id, appInfoID: appInfo?.id)
        let needsVersion = !fields.isDisjoint(with: ASCEditability.versionFields.union(ASCEditability.anytimeVersionFields))
        if needsVersion {
            let versions = try await service.fetchAppStoreVersions(appId: appID)
            try checkWriteTarget(target)
            guard versions.contains(where: { $0.id == target.versionID }) else { throw ASCError.notFound("Die ausgewählte Version existiert nicht mehr.") }
            appStoreVersions = versions
        }
        if !fields.isDisjoint(with: ASCEditability.appInfoFields) {
            guard let id = target.appInfoID else { throw ASCError.notFound("App-Informationen sind noch nicht geladen.") }
            let info = try await service.fetchAppInfoRecord(id: id)
            try checkWriteTarget(target)
            guard info.id == id else { throw ASCError.notFound("App-Informationen haben sich geändert.") }
            appInfo = info
        }
        try checkWriteTarget(target)
        for field in fields where !canEditField(field) { throw ASCError.notFound(editingBlockedMessage(field)) }
        return target
    }
}
