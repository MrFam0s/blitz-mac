import Foundation

struct ReleaseReadinessPayload: Sendable {
    let report: Data
    let web: ReleaseWebEvidence
    let exitCode: Int
}

struct ReleaseReadinessDiagnostic: Codable, Equatable, Sendable {
    let id: String
    let status: String
    let source: String
    let reason: String
    var locale: String? = nil
    var guidance: String? = nil
}

/// Sanitized evidence only. The helper never returns session material, legal
/// entity details, signed agreement links or arbitrary Apple error bodies.
struct ReleaseWebEvidence: Codable, Equatable, Sendable {
    struct Check: Codable, Equatable, Sendable {
        let status: String
        let reason: String
    }
    let appId: String
    let bundleId: String
    let bindingVerified: Bool
    let bindingReason: String
    var appleId: String? = nil
    var providerId: String? = nil
    var developerTeamId: String? = nil
    let programLicense: Check
    let businessFree: Check
    let businessPaid: Check

    static func unavailable(_ target: ReleaseWorkflowTarget) -> Self {
        let unknown = Check(status: "unverified", reason: "web_session_unavailable")
        return Self(appId: target.appID, bundleId: target.bundleID, bindingVerified: false,
                    bindingReason: "web_session_unavailable", programLicense: unknown,
                    businessFree: unknown, businessPaid: unknown)
    }

    func matches(_ other: Self, target: ReleaseWorkflowTarget) -> Bool {
        bindingVerified && other.bindingVerified && appId == target.appID && bundleId == target.bundleID
            && other.appId == target.appID && other.bundleId == target.bundleID
            && appleId?.isEmpty == false && appleId == other.appleId
            && providerId?.isEmpty == false && providerId == other.providerId
    }
}

enum ReleaseReadinessPolicy {
    /// Classification is platform-specific and uses the complete fresh history.
    /// A developer-withdrawn first release stays first even when its number is 1.2.
    static func isFirstPublication(versions: [[String: Any]], target: ReleaseWorkflowTarget) throws -> Bool {
        var foundTarget = false
        var published = false
        let unpublished: Set<String> = ["ACCEPTED", "DEVELOPER_REJECTED", "IN_REVIEW", "INVALID_BINARY",
            "METADATA_REJECTED", "PENDING_APPLE_RELEASE", "PENDING_CONTRACT", "PENDING_DEVELOPER_RELEASE",
            "PREORDER_READY_FOR_SALE", "PREPARE_FOR_SUBMISSION", "PROCESSING_FOR_APP_STORE",
            "PROCESSING_FOR_DISTRIBUTION", "READY_FOR_REVIEW", "REJECTED", "WAITING_FOR_EXPORT_COMPLIANCE",
            "WAITING_FOR_REVIEW", "NOT_APPLICABLE"]
        for version in versions {
            guard let attrs = version["attributes"] as? [String: Any],
                  let platform = attrs["platform"] as? String else { throw ReleaseWorkflowAPIError.validationUnavailable }
            guard platform == target.platform else { continue }
            if version["id"] as? String == target.versionID { foundTarget = true }
            let state = ((attrs["appVersionState"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? attrs["appStoreState"] as? String ?? "").uppercased()
            if ASCReleaseStatus.publishedStates.contains(state) { published = true }
            else if !unpublished.contains(state) { throw ReleaseWorkflowAPIError.validationUnavailable }
        }
        guard foundTarget else { throw ReleaseWorkflowError.identityChanged }
        return !published
    }

    static func normalize(report: [String: Any], exitCode: Int, target: ReleaseWorkflowTarget,
                          firstPublication: Bool, localizations: [[String: Any]],
                          web: ReleaseWebEvidence, webBindingStable: Bool) throws -> ReleaseWorkflowValidation {
        guard report["appId"] as? String == target.appID, report["versionId"] as? String == target.versionID,
              report["platform"] as? String == target.platform,
              let summary = report["summary"] as? [String: Any],
              let blocking = summary["blocking"] as? Int, let warnings = summary["warnings"] as? Int,
              let checks = report["checks"] as? [[String: Any]],
              let deep = report["deep"] as? [String: Any],
              let deepSummary = deep["summary"] as? [String: Any],
              let deepBlocked = deepSummary["blocked"] as? Int, let deepUnverified = deepSummary["unverified"] as? Int,
              let deepChecks = deep["checks"] as? [[String: Any]],
              blocking >= 0, warnings >= 0, deepBlocked >= 0, deepUnverified >= 0 else {
            throw ReleaseWorkflowAPIError.validationUnavailable
        }
        // Refuse partial reports and non-validation command failures. Only known
        // findings can be normalized; an unexplained failed process stays failed.
        guard checks.allSatisfy({ $0["id"] is String && ["info", "warning", "error"].contains($0["severity"] as? String ?? "") }),
              deepChecks.allSatisfy({ $0["id"] is String && ["passed", "blocked", "unverified", "notApplicable"].contains($0["status"] as? String ?? "") }),
              checks.filter({ $0["severity"] as? String == "warning" }).count == warnings,
              checks.filter({ ["error", "warning"].contains($0["severity"] as? String ?? "") }).count == blocking,
              deepChecks.filter({ $0["status"] as? String == "blocked" }).count == deepBlocked,
              deepChecks.filter({ $0["status"] as? String == "unverified" }).count == deepUnverified,
              exitCode == 0 || blocking > 0 else { throw ReleaseWorkflowAPIError.validationUnavailable }

        var normalized = checks.filter { !($0["id"] as? String == "metadata.required.whats_new" && $0["severity"] as? String == "warning") }
        var diagnostics: [ReleaseReadinessDiagnostic] = []
        if firstPublication {
            diagnostics.append(.init(id: "metadata.required.whats_new", status: "notApplicable", source: "publicApi",
                reason: "first_publication_verified_from_complete_platform_history"))
        } else {
            guard !localizations.isEmpty else { throw ReleaseWorkflowAPIError.validationUnavailable }
            for localization in localizations {
                guard let attrs = localization["attributes"] as? [String: Any], let locale = attrs["locale"] as? String,
                      !locale.isEmpty else { throw ReleaseWorkflowAPIError.validationUnavailable }
                let value = (attrs["whatsNew"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty {
                    normalized.append(["id": "metadata.required.whats_new", "severity": "warning", "locale": locale])
                }
            }
        }

        // Replace only the generic *unknown* agreement finding. Known pending or
        // alert errors are preserved even if another endpoint appears healthy.
        normalized.removeAll { $0["id"] as? String == "deep.agreements.active.unverified" }
        let observedDeep = deepChecks.filter { $0["id"] as? String != "agreements.active" || $0["status"] as? String == "blocked" }
        var effectiveDeep = observedDeep
        let evidenceChecks: [(String, ReleaseWebEvidence.Check)] = [
            ("agreements.program_license", web.programLicense), ("agreements.business.free", web.businessFree),
            ("agreements.business.paid", web.businessPaid)]
        for (id, evidence) in evidenceChecks {
            let status = webBindingStable ? evidence.status : "unverified"
            guard ["passed", "blocked", "unverified", "notApplicable"].contains(status) else { throw ReleaseWorkflowAPIError.validationUnavailable }
            let reason = webBindingStable ? evidence.reason : (web.bindingVerified ? "web_provider_changed" : web.bindingReason)
            effectiveDeep.append(["id": id, "status": status, "source": "providerBoundWeb"])
            diagnostics.append(.init(id: id, status: status, source: "providerBoundWeb", reason: reason,
                guidance: guidance(reason)))
        }
        if !webBindingStable {
            // Other web results must not be accepted from a different/default cache.
            for index in effectiveDeep.indices where effectiveDeep[index]["source"] as? String == "webSession" {
                effectiveDeep[index]["status"] = "unverified"
            }
        }
        for check in normalized {
            let id = check["id"] as! String, severity = check["severity"] as! String
            diagnostics.append(.init(id: id, status: severity == "info" ? "info" : "blocked", source: "asc",
                reason: id == "metadata.required.whats_new" ? "published_platform_history_requires_changelog" : "asc_\(severity)",
                locale: check["locale"] as? String))
        }
        for check in effectiveDeep where !(check["id"] as! String).hasPrefix("agreements.") {
            diagnostics.append(.init(id: check["id"] as! String, status: check["status"] as! String,
                source: check["source"] as? String ?? "asc", reason: "deep_\(check["status"] as! String)"))
        }
        if observedDeep.contains(where: { $0["id"] as? String == "agreements.active" && $0["status"] as? String == "blocked" }) {
            diagnostics.append(.init(id: "agreements.active", status: "blocked", source: "asc", reason: "asc_reported_agreement_blocker"))
        }
        let effectiveWarnings = normalized.filter { $0["severity"] as? String == "warning" }.count
        let flatBlocking = normalized.filter { ["error", "warning"].contains($0["severity"] as? String ?? "") }.count
        let unknown = effectiveDeep.filter { $0["status"] as? String == "unverified" }.count
        // Upstream deep checks duplicate base findings; count only independent
        // deep blockers instead of adding the complete deep summary twice.
        let duplicatePrefixes = ["privacy.publish_state": "privacy.", "availability.configured": "availability.",
            "review_information.required_fields": "review_details.", "iap.first_type_app_version_attachment": "iap.",
            "subscriptions.first_type_app_version_attachment": "subscriptions.", "agreements.active": "agreements."]
        let independentDeep = effectiveDeep.filter { check in
            guard check["status"] as? String == "blocked" else { return false }
            guard let prefix = duplicatePrefixes[check["id"] as? String ?? ""] else { return true }
            return !normalized.contains { ($0["id"] as? String)?.hasPrefix(prefix) == true && $0["severity"] as? String != "info" }
        }.count
        let totalBlocking = flatBlocking + independentDeep
        return ReleaseWorkflowValidation(ready: totalBlocking == 0 && unknown == 0, blocking: totalBlocking,
            warnings: effectiveWarnings, unverified: unknown,
            checkIDs: diagnostics.map(\.id).sorted(), diagnostics: diagnostics)
    }

    private static func guidance(_ reason: String) -> String? {
        switch reason {
        case "developer_team_unresolved":
            return "Business-Verträge und Programmlizenz sind getrennt. Das Developer-Portal-Team der bestätigten App konnte nicht aufgelöst werden. Im selben Apple-Konto unter developer.apple.com/account das richtige Team und die Mitgliedschaft prüfen; anschließend die Webanmeldung erneuern und erneut validieren."
        case "developer_portal_auth_required", "web_session_expired", "web_session_unavailable":
            return "Die bestehende Apple-Websitzung reicht für diese Prüfung nicht aus. Mit dem Konto der App erneut anmelden und die bestehende Release-Operation erneut validieren."
        case "web_provider_app_mismatch_or_inaccessible", "web_provider_unresolved", "web_provider_changed":
            return "Die Websitzung konnte nicht eindeutig dem Konto dieser App zugeordnet werden. In App Store Connect den richtigen Anbieter auswählen und erneut validieren."
        case "program_license_acceptance_required", "business_agreement_action_required":
            return "Der Account Holder muss den bezeichneten Vertrag bei Apple prüfen. Blitz akzeptiert keine Verträge automatisch. Danach erneut validieren."
        case "program_license_history_missing", "developer_portal_unavailable", "program_license_status_unknown", "outstanding_agreement_classification_unknown", "program_license_conflicting_history":
            return "Die aktuelle Apple Developer Program License ist nicht vollständig nachgewiesen. Aktive Business-Verträge ersetzen diesen Nachweis nicht; Developer-Portal-Sitzung und Lizenzstatus prüfen und erneut validieren."
        case "business_agreements_unavailable", "business_agreement_fields_missing", "business_agreement_missing_or_ambiguous", "business_agreement_status_unknown":
            return "Den bezeichneten Vertrag unter App Store Connect → Business prüfen und erneut validieren. Der Status ist ungeklärt, nicht als inaktiv bestätigt."
        case "paid_agreement_relevance_unknown":
            return "App-Preis und aktive In-App-Käufe/Abonnements konnten nicht vollständig bestimmt werden. Diese Daten zuerst aktualisieren und erneut validieren."
        default: return nil
        }
    }
}
