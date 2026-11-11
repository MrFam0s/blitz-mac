// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import AppKit
import Foundation
import ImageIO

extension MCPExecutor {
    // MARK: - ASC Form Tools

    private static let appInformationDetailFieldWriteOrder = [
        "copyright",
        "primaryCategory",
        "contentRightsDeclaration",
    ]

    private static let appInformationLocalizationFields: Set<String> = [
        "title", "name", "subtitle", "description", "keywords", "promotionalText",
        "marketingUrl", "supportUrl", "whatsNew", "privacyPolicyUrl",
    ]

    static let validFieldsByTab: [String: Set<String>] = [
        MCPAppInformationCompatibility.canonicalTab: appInformationLocalizationFields
            .union(appInformationDetailFieldWriteOrder),
        "monetization": ["isFree"],
        "review.ageRating": ["gambling", "messagingAndChat", "unrestrictedWebAccess",
                             "userGeneratedContent", "advertising", "lootBox",
                             "healthOrWellnessTopics", "parentalControls", "ageAssurance",
                             "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated",
                             "gunsOrOtherWeapons", "horrorOrFearThemes", "matureOrSuggestiveThemes",
                             "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
                             "sexualContentGraphicAndNudity", "sexualContentOrNudity",
                             "violenceCartoonOrFantasy", "violenceRealistic",
                             "violenceRealisticProlongedGraphicOrSadistic"],
        "review.contact": ["contactFirstName", "contactLastName", "contactEmail", "contactPhone",
                           "notes", "demoAccountRequired", "demoAccountName", "demoAccountPassword"],
        "settings.bundleId": ["bundleId"],
    ]

    static let fieldAliases: [String: String] = [
        "firstName": "contactFirstName",
        "lastName": "contactLastName",
        "email": "contactEmail",
        "phone": "contactPhone",
    ]

    static let reviewContactRequiredFieldKeys = [
        "contactFirstName",
        "contactLastName",
        "contactEmail",
        "contactPhone",
    ]

    static func normalizedReviewContactDraft(_ fields: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (field, value) in fields {
            if field == "contactPhone" {
                let stripped = value.hasPrefix("+")
                    ? "+" + value.dropFirst().filter(\.isNumber)
                    : value.filter(\.isNumber)
                normalized[field] = stripped
            } else if field == "demoAccountRequired" {
                normalized[field] = value == "true" ? "true" : "false"
            } else {
                normalized[field] = value
            }
        }
        return normalized
    }

    static func reviewContactStringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func missingRequiredReviewContactFields(from attributes: [String: Any]) -> [String] {
        var missing = reviewContactRequiredFieldKeys.filter {
            reviewContactStringValue(attributes[$0]) == nil
        }

        let demoRequired = attributes["demoAccountRequired"] as? Bool == true
        if demoRequired {
            if reviewContactStringValue(attributes["demoAccountName"]) == nil {
                missing.append("demoAccountName")
            }
            if reviewContactStringValue(attributes["demoAccountPassword"]) == nil {
                missing.append("demoAccountPassword")
            }
        }

        return missing
    }

    static func mergedReviewContactAttributes(
        reviewDetail: ASCReviewDetail?,
        draft: [String: String]
    ) -> [String: Any] {
        var attributes: [String: Any] = [:]

        if let existing = reviewDetail?.attributes {
            if let contactFirstName = existing.contactFirstName, !contactFirstName.isEmpty {
                attributes["contactFirstName"] = contactFirstName
            }
            if let contactLastName = existing.contactLastName, !contactLastName.isEmpty {
                attributes["contactLastName"] = contactLastName
            }
            if let contactPhone = existing.contactPhone, !contactPhone.isEmpty {
                attributes["contactPhone"] = contactPhone
            }
            if let contactEmail = existing.contactEmail, !contactEmail.isEmpty {
                attributes["contactEmail"] = contactEmail
            }
            if let demoAccountRequired = existing.demoAccountRequired {
                attributes["demoAccountRequired"] = demoAccountRequired
            }
            if let demoAccountName = existing.demoAccountName, !demoAccountName.isEmpty {
                attributes["demoAccountName"] = demoAccountName
            }
            if let demoAccountPassword = existing.demoAccountPassword, !demoAccountPassword.isEmpty {
                attributes["demoAccountPassword"] = demoAccountPassword
            }
            if let notes = existing.notes, !notes.isEmpty {
                attributes["notes"] = notes
            }
        }

        for (field, value) in draft {
            if field == "demoAccountRequired" {
                attributes[field] = value == "true"
            } else {
                attributes[field] = value
            }
        }

        return attributes
    }

    static func missingRequiredReviewContactFieldsForInitialCreate(
        reviewDetail: ASCReviewDetail?,
        mergedAttributes: [String: Any]
    ) -> [String] {
        guard reviewDetail?.isPlaceholder != false else { return [] }
        return missingRequiredReviewContactFields(from: mergedAttributes)
    }

    @MainActor
    static func screenshotSaveDisplayTypes(
        requestedDisplayType: String?,
        locale: String,
        projectDisplayTypes: [String],
        asc: ASCManager
    ) -> [String] {
        if let requestedDisplayType {
            let trimmed = requestedDisplayType.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return [trimmed]
            }
        }

        let knownDisplayTypes = asc.orderedKnownScreenshotDisplayTypes(
            for: locale,
            preferredOrder: projectDisplayTypes
        )
        let candidateDisplayTypes = knownDisplayTypes.isEmpty ? projectDisplayTypes : knownDisplayTypes
        let stagedDisplayTypes = candidateDisplayTypes.filter {
            asc.hasTrackState(displayType: $0, locale: locale)
                || asc.hasUnsavedChanges(displayType: $0, locale: locale)
        }
        return stagedDisplayTypes.isEmpty ? candidateDisplayTypes : stagedDisplayTypes
    }

    private func screenshotsDisplayTypesForActiveProject() async -> [String] {
        await MainActor.run {
            switch appState.ascManager.releasePlatform {
            case .iOS:
                return ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"]
            case .macOS:
                return ["APP_DESKTOP"]
            case nil: return []
            }
        }
    }

    private func resolveAppInformationLocale(from args: [String: Any]) async -> String {
        if let requestedLocale = (args["locale"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedLocale.isEmpty {
            return requestedLocale
        }

        return await MainActor.run {
            appState.ascManager.activeAppInformationLocale() ?? "en-US"
        }
    }

    private func prepareAppInformationLocale(
        _ locale: String,
        forceRefresh: Bool = false
    ) async throws -> String? {
        let trimmedLocale = locale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLocale.isEmpty else {
            return "Error: locale is required."
        }

        let needsRefresh = try await scopedUI { () -> Bool in
            let asc = appState.ascManager
            asc.selectedAppInformationLocale = trimmedLocale
            return forceRefresh
                || asc.localizations.isEmpty
                || !asc.localizations.contains(where: { $0.attributes.locale == trimmedLocale })
                || asc.appInfoLocalizationsByLocale.isEmpty
        }

        if needsRefresh {
            await appState.ascManager.refreshTabData(.appInformation)
        }

        let availableLocales = try await scopedUI {
            appState.ascManager.localizations.map(\.attributes.locale).sorted()
        }
        guard availableLocales.contains(trimmedLocale) else {
            let availableText = availableLocales.isEmpty ? "none" : availableLocales.joined(separator: ", ")
            return "Error: app information localization '\(trimmedLocale)' was not found after refreshing from ASC. "
                + "Available localizations: \(availableText)"
        }

        try await scopedUI {
            appState.ascManager.selectedAppInformationLocale = trimmedLocale
        }
        return nil
    }

    private func resolveScreenshotsLocale(from args: [String: Any]) async -> (locale: String, explicitlyRequested: Bool) {
        if let requestedLocale = (args["locale"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedLocale.isEmpty {
            return (requestedLocale, true)
        }

        let locale = await MainActor.run {
            appState.ascManager.selectedScreenshotsLocale
                ?? appState.ascManager.localizations.first?.attributes.locale
                ?? "en-US"
        }
        return (locale, false)
    }

    private func activeVersionScopedTabForRefresh() async -> AppTab {
        await MainActor.run {
            switch appState.activeTab {
            case .appInformation, .screenshots, .review:
                return appState.activeTab
            default:
                return .app
            }
        }
    }

    private func versionPayload(_ version: ASCAppStoreVersion) -> [String: Any] {
        var payload: [String: Any] = [
            "id": version.id,
            "versionString": version.attributes.versionString,
            "state": version.attributes.appStoreState ?? "unknown",
        ]
        if let createdDate = version.attributes.createdDate {
            payload["createdDate"] = createdDate
        }
        if let releaseType = version.attributes.releaseType {
            payload["releaseType"] = releaseType
        }
        return payload
    }

    func executeASCSetCredentials(_ args: [String: Any]) async -> [String: Any] {
        guard let issuerId = args["issuerId"] as? String,
              let rawPath = args["privateKeyPath"] as? String else {
            return mcpText("Error: issuerId and privateKeyPath are required.")
        }

        let path = NSString(string: rawPath).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let privateKey = try? String(contentsOfFile: path, encoding: .utf8),
              !privateKey.isEmpty else {
            return mcpText("Error: could not read private key file at \(rawPath)")
        }

        let explicitKeyId = (args["keyId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyId = (explicitKeyId?.isEmpty == false ? explicitKeyId : nil)
            ?? ASCCredentials.keyID(fromPrivateKeyFilename: path) else {
            return mcpText(
                "Error: keyId was not provided and could not be derived from privateKeyPath. "
                + "Use Apple's original AuthKey_<KEYID>.p8 filename or pass keyId explicitly."
            )
        }

        await MainActor.run {
            appState.ascManager.pendingCredentialValues = [
                "issuerId": issuerId,
                "keyId": keyId,
                "privateKey": privateKey,
                "privateKeyFileName": URL(fileURLWithPath: path).lastPathComponent
            ]
        }
        return mcpText("Credentials pre-filled. The user can verify and confirm in the UI.")
    }

    func executeASCReopenAppSetup(_ args: [String: Any]) async -> [String: Any] {
        guard let projectID = args["projectId"] as? String, !projectID.isEmpty,
              let operationID = args["operationId"] as? String, !operationID.isEmpty,
              args["message"] == nil || args["message"] is String else {
            return mcpText("Error: projectId and operationId from the confirmed identity JSON are required; message must be plain text.")
        }
        let result: [String: Any] = await MainActor.run {
            do {
                guard appState.activeProjectId == projectID else {
                    throw ASCManager.BundleIDSetupConfirmationError.staleOperation
                }
                let request = try appState.ascManager.reopenAppCreationForm(projectId: projectID,
                    operationId: operationID, message: args["message"] as? String)
                appState.activeTab = request.context.tab
                if request.context.tab == .app { appState.activeAppSubTab = .overview }
                return ["success": true, "projectId": projectID, "phase": "identityForm",
                    "requiresNewConfirmation": true, "appleMutationPerformed": false]
            } catch { return ["success": false, "error": error.localizedDescription] }
        }
        return mcpJSON(result)
    }

    func executeASCConfirmCreatedApp(_ args: [String: Any]) async -> [String: Any] {
        let required = ["bundleId", "expectedName", "expectedSKU", "expectedPlatform", "expectedLocale", "projectId", "operationId"]
        guard required.allSatisfy({ (args[$0] as? String)?.isEmpty == false }) else {
            return mcpText("Error: pass the complete confirmed identity and projectId/operationId from the app-creation identity file. Unscoped confirmations are not accepted.")
        }
        let bundleId = args["bundleId"] as! String

        for attempt in 1...10 {
            do {
                let app = try await appState.ascManager.confirmBundleIDSetupAppCreated(bundleId: bundleId,
                    expectedName: args["expectedName"] as? String, expectedSKU: args["expectedSKU"] as? String,
                    expectedPlatform: args["expectedPlatform"] as? String, expectedLocale: args["expectedLocale"] as? String,
                    projectId: args["projectId"] as? String, operationId: args["operationId"] as? String,
                    releaseTargetId: args["releaseTargetId"] as? String)
                return mcpJSON([
                    "success": true,
                    "attempts": attempt,
                    "appId": app.id,
                    "bundleId": app.bundleId,
                    "name": app.attributes.name,
                    "sku": app.attributes.sku ?? "",
                    "primaryLocale": app.primaryLocale ?? "",
                ])
            } catch let ascError as ASCError {
                if case .notFound = ascError {
                    if attempt < 10 {
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }

                    return mcpText("Error: app with bundle ID '\(bundleId)' was not found in App Store Connect after 10 read-only checks. Creation remains unconfirmed; this does not prove the bundle ID is invalid. Do not retry creation automatically. Use asc_reopen_app_setup with the original projectId/operationId to return to the identity form.")
                }

                return mcpText("Error: \(ascError.localizedDescription)")
            } catch {
                return mcpText("Error: \(error.localizedDescription)")
            }
        }

        return mcpText("Error: app was not found in App Store Connect after 10 checks.")
    }

    func executeASCFillForm(_ args: [String: Any]) async throws -> [String: Any] {
        guard let rawTab = args["tab"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let tab = MCPAppInformationCompatibility.canonicalTabName(rawTab)

        let fieldMap = parseFieldMap(args["fields"], applyAliases: true)
        guard !fieldMap.isEmpty else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        var resolvedAppInformationLocale: String?

        if let validFields = Self.validFieldsByTab[tab] {
            let invalid = fieldMap.keys.filter { !validFields.contains($0) }
            if !invalid.isEmpty {
                var hints: [String] = []
                for field in invalid {
                    for (otherTab, otherFields) in Self.validFieldsByTab where otherTab != tab {
                        if otherFields.contains(field) {
                            hints.append("'\(field)' belongs on tab '\(otherTab)'")
                        }
                    }
                }
                let hintStr = hints.isEmpty ? "" : " Hint: \(hints.joined(separator: "; "))."
                return mcpText(
                    "Error: invalid field(s) for tab '\(tab)': \(invalid.sorted().joined(separator: ", ")). "
                        + "Valid fields: \(validFields.sorted().joined(separator: ", ")).\(hintStr)"
                )
            }
        }

        var extraResponse: [String: Any] = [:]

        switch tab {
        case MCPAppInformationCompatibility.canonicalTab:
            let appInfoLocFields: Set<String> = ["name", "title", "subtitle", "privacyPolicyUrl"]
            var versionLocFields: [String: String] = [:]
            var infoLocFields: [String: String] = [:]
            var detailFields: [String: String] = [:]
            let hasLocalizedFields = fieldMap.keys.contains { Self.appInformationLocalizationFields.contains($0) }

            if hasLocalizedFields {
                let locale = await resolveAppInformationLocale(from: args)
                resolvedAppInformationLocale = locale

                if let localeError = try await prepareAppInformationLocale(locale) {
                    _ = try await scopedUI { appState.ascManager.pendingFormValues.removeValue(forKey: tab) }
                    return mcpText(localeError)
                }
            }

            for (field, value) in fieldMap {
                if appInfoLocFields.contains(field) {
                    infoLocFields[field] = value
                } else if Self.appInformationDetailFieldWriteOrder.contains(field) {
                    detailFields[field] = value
                } else {
                    versionLocFields[field] = value
                }
            }

            // Validate the complete batch before any localized/detail write can succeed.
            do {
                guard let service = await appState.ascManager.service else { return mcpText("Error: ASC is not connected.") }
                _ = try await appState.ascManager.validateWrite(fields: Set(fieldMap.keys), using: service)
            } catch { return mcpText("Error: \(error.localizedDescription)") }

            if hasLocalizedFields, let locale = resolvedAppInformationLocale {
                await appState.ascManager.updateAppInformationFields(
                    versionFields: versionLocFields,
                    appInfoFields: infoLocFields,
                    locale: locale
                )
                if let err = await checkASCWriteError(tab: tab) { return err }
            }

            for field in Self.appInformationDetailFieldWriteOrder {
                guard let value = detailFields[field] else { continue }
                await appState.ascManager.updateAppInfoField(field, value: value)
                if let err = await checkASCWriteError(tab: tab) { return err }
            }

        case "monetization":
            guard let isFree = fieldMap["isFree"] else {
                return mcpText(
                    "Error: monetization tab requires the 'isFree' field (value: \"true\" or \"false\")."
                )
            }
            if isFree == "true" {
                try await MCPMutationScope.checkBeforeWrite()
                await appState.ascManager.setPriceFree()
            } else {
                return mcpText(
                    "To set a paid price, use the asc_set_app_price tool with a price parameter (e.g. price=\"0.99\")."
                )
            }
            if let err = await checkASCWriteError(tab: tab) { return err }

        case "review.ageRating":
            var attrs: [String: Any] = [:]
            let boolFields = Set(["gambling", "messagingAndChat", "unrestrictedWebAccess",
                                  "userGeneratedContent", "advertising", "lootBox",
                                  "healthOrWellnessTopics", "parentalControls", "ageAssurance"])
            for (field, value) in fieldMap {
                attrs[field] = boolFields.contains(field) ? (value == "true") : value
            }
            try await MCPMutationScope.checkBeforeWrite()
            await appState.ascManager.updateAgeRating(attrs)
            if let err = await checkASCWriteError(tab: tab) { return err }

        case "review.contact":
            let normalizedDraft = try await scopedUI { () -> [String: String] in
                let merged = (appState.ascManager.pendingFormValues[tab] ?? [:]).merging(fieldMap) { _, new in new }
                let normalized = Self.normalizedReviewContactDraft(merged)
                return normalized
            }

            let mergedAttributes = try await scopedUI {
                Self.mergedReviewContactAttributes(
                    reviewDetail: appState.ascManager.reviewDetail,
                    draft: normalizedDraft
                )
            }

            let missingInitialCreateFields = try await scopedUI {
                Self.missingRequiredReviewContactFieldsForInitialCreate(
                    reviewDetail: appState.ascManager.reviewDetail,
                    mergedAttributes: mergedAttributes
                )
            }
            if !missingInitialCreateFields.isEmpty {
                try await scopedUI {
                    if appState.ascManager.pendingFormValues.removeValue(forKey: tab) != nil {
                        appState.ascManager.pendingFormVersion += 1
                    }
                    appState.ascManager.writeError = nil
                }
                return mcpText(
                    "Error: App Store Connect requires \(missingInitialCreateFields.joined(separator: ", ")) "
                        + "to create the initial review contact resource. Re-send the full required contact block together."
                )
            }

            await appState.ascManager.updateReviewContact(mergedAttributes)

            let reviewContactWriteError = try await scopedUI { () -> String? in
                let asc = appState.ascManager
                let error = asc.writeError
                asc.writeError = nil

                if error == nil {
                    if asc.pendingFormValues.removeValue(forKey: tab) != nil {
                        asc.pendingFormVersion += 1
                    }
                }

                return error
            }
            if let reviewContactWriteError {
                return mcpText("Error: \(reviewContactWriteError)")
            }

            let persistedMissingRequired = try await scopedUI {
                Self.missingRequiredReviewContactFields(
                    from: Self.mergedReviewContactAttributes(
                        reviewDetail: appState.ascManager.reviewDetail,
                        draft: [:]
                    )
                )
            }
            extraResponse["saved"] = true
            extraResponse["pending"] = false
            extraResponse["missingRequired"] = persistedMissingRequired
            if persistedMissingRequired.isEmpty {
                extraResponse["message"] = "Review contact was saved to ASC."
            } else {
                extraResponse["message"] =
                    "Review contact was saved to ASC. Required fields still missing in App Store Connect: \(persistedMissingRequired.joined(separator: ", "))."
            }

        case "settings.bundleId":
            if let bundleId = fieldMap["bundleId"] {
                guard AppCreationIdentity.validBundleID(bundleId) else {
                    return mcpText("Error: invalid bundle ID. Preserve the original spelling and use nonempty ASCII components separated by dots.")
                }
                // Both local files are updated in one MainActor turn. A project
                // switch cannot interleave between the Xcode and metadata writes.
                let context = try await scopedUI {
                    let storage = ProjectStorage()
                    guard let project = appState.activeProject,
                          var metadata = storage.readMetadata(projectId: project.id) else {
                        throw ASCManager.BundleIDSetupConfirmationError.projectUnavailable
                    }
                    let asc = appState.ascManager
                    let originalRevision = asc.projectRevision
                    let originalAccount = DashboardSummaryStore.accountKey(for: asc.credentials)
                    try ProjectBundleIDTransaction.update(projectPath: project.path, bundleID: bundleId,
                        scheme: metadata.buildSettings?.scheme, configuration: metadata.buildSettings?.configuration) {
                        metadata.bundleIdentifier = bundleId
                        try storage.writeMetadata(projectId: project.id, metadata: metadata)
                    }
                    return (projectId: project.id, revision: originalRevision, account: originalAccount)
                }
                await appState.projectManager.loadProjects()
                let mayRefresh = try await scopedUI {
                    appState.activeProjectId == context.projectId && appState.ascManager.projectRevision == context.revision
                        && DashboardSummaryStore.accountKey(for: appState.ascManager.credentials) == context.account
                }
                guard mayRefresh else { throw ASCManager.BundleIDSetupConfirmationError.staleOperation }
                _ = await appState.ascManager.fetchApp(bundleId: bundleId)
            }

        default:
            return mcpText("Unknown tab: \(tab)")
        }

        _ = try await scopedUI { appState.ascManager.pendingFormValues.removeValue(forKey: tab) }
        var response: [String: Any] = ["success": true, "tab": tab, "fieldsUpdated": fieldMap.count]
        if let resolvedAppInformationLocale {
            response["locale"] = resolvedAppInformationLocale
        }
        for (key, value) in extraResponse {
            response[key] = value
        }
        return mcpJSON(response)
    }

    func executeAppInformationSwitchLocalization(_ args: [String: Any]) async throws -> [String: Any] {
        guard let rawLocale = args["locale"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let locale = rawLocale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locale.isEmpty else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        if let localeError = try await prepareAppInformationLocale(locale, forceRefresh: true) {
            return mcpText(localeError)
        }

        let state = try await scopedUI { () -> [String: Any] in
            let asc = appState.ascManager
            let versionLocalization = asc.appInformationLocalization(locale: locale)
            let appInfoLocalization = asc.appInfoLocalizationForLocale(locale)
            let fields: [String: String] = [
                "name": appInfoLocalization?.attributes.name ?? versionLocalization?.attributes.title ?? "",
                "subtitle": appInfoLocalization?.attributes.subtitle ?? versionLocalization?.attributes.subtitle ?? "",
                "description": versionLocalization?.attributes.description ?? "",
                "keywords": versionLocalization?.attributes.keywords ?? "",
                "promotionalText": versionLocalization?.attributes.promotionalText ?? "",
                "marketingUrl": versionLocalization?.attributes.marketingUrl ?? "",
                "supportUrl": versionLocalization?.attributes.supportUrl ?? "",
                "whatsNew": versionLocalization?.attributes.whatsNew ?? "",
                "privacyPolicyUrl": appInfoLocalization?.attributes.privacyPolicyUrl ?? ""
            ]
            var response: [String: Any] = [
                "success": true,
                "locale": locale,
                "availableLocales": asc.localizations.map(\.attributes.locale).sorted(),
                "hasAppInfoLocalization": appInfoLocalization != nil,
                "details": [
                    "copyright": asc.selectedVersion?.attributes.copyright ?? "",
                    "primaryCategory": asc.appInfo?.primaryCategoryId ?? "",
                    "contentRightsDeclaration": asc.app?.contentRightsDeclaration ?? "",
                ],
            ]
            response["fields"] = fields
            return response
        }

        return mcpJSON(state)
    }

    func executeASCSelectVersion(_ args: [String: Any]) async throws -> [String: Any] {
        guard let identifier = (args["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        guard let target = await MainActor.run(body: { () -> ASCReleaseOperationTarget? in
            guard Self.releaseApprovalTargetMatches(appState) else { return nil }
            return appState.ascManager.releaseOperationTarget()
        }) else { return mcpText("Error: no unchanged app is selected.") }
        await appState.ascManager.ensureTabData(.app)
        guard await MainActor.run(body: { target.matches(appState.ascManager) }) else { return mcpText("Error: app or version changed; retry for the intended target.") }
        var resolvedVersion = await MainActor.run { appState.ascManager.version(matching: identifier) }
        if resolvedVersion == nil {
            await appState.ascManager.refreshTabData(.app)
            guard await MainActor.run(body: { target.matches(appState.ascManager) }) else { return mcpText("Error: app or version changed; retry for the intended target.") }
            resolvedVersion = await MainActor.run { appState.ascManager.version(matching: identifier) }
        }
        guard let resolvedVersion else { return mcpText("Error: app version '\(identifier)' was not found for this platform.") }
        let refreshTab = await activeVersionScopedTabForRefresh()
        guard let selectedTarget = await MainActor.run(body: { () -> ASCReleaseOperationTarget? in
            guard target.matches(appState.ascManager) else { return nil }
            appState.ascManager.prepareForVersionSelection(resolvedVersion.id)
            return appState.ascManager.releaseOperationTarget()
        }) else { return mcpText("Error: app or version changed; retry for the intended target.") }
        await appState.ascManager.refreshTabData(refreshTab)
        guard await MainActor.run(body: { selectedTarget.matches(appState.ascManager) }) else { return mcpText("Error: selection changed while refreshing.") }
        let next = try await MainActor.run { try Self.contextAfterVersionTransition(resolvedVersion.id, appState: appState) }
        return mcpJSON(["success": true, "refreshedTab": refreshTab.rawValue,
            "selectedVersion": versionPayload(resolvedVersion), "expectedTarget": next])
    }

    func executeASCCreateVersion(_ args: [String: Any]) async throws -> [String: Any] {
        guard let versionString = (args["versionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !versionString.isEmpty else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let copyFromVersion = (args["copyFromVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachBuildId = (args["attachBuildId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = await MainActor.run(body: { () -> ASCReleaseOperationTarget? in
            guard Self.releaseApprovalTargetMatches(appState) else { return nil }
            return appState.ascManager.releaseOperationTarget()
        }), let platform = target.platform else { return mcpText("Error: no unchanged app and platform are selected.") }
        let created = await appState.ascManager.createUpdateVersion(
            versionString: versionString, platform: platform,
            copyFromVersionId: copyFromVersion,
            copyMetadata: args["copyMetadata"] as? Bool ?? true,
            copyReviewDetail: args["copyReviewDetail"] as? Bool ?? true,
            attachBuildId: attachBuildId?.isEmpty == false ? attachBuildId : nil,
            expectedTarget: target)
        guard let created else {
            let error = await MainActor.run { target.matches(appState.ascManager) ? appState.ascManager.versionCreationError : nil }
            return mcpText("Error: \(error ?? "Version creation did not complete for the captured target. Re-read the intended app before retrying.")")
        }
        // The result belongs to the captured operation, never a later selection.
        var response: [String: Any] = ["success": true, "appId": target.appId,
            "selectedVersion": versionPayload(created), "canCreateUpdate": false]
        if let next = try? await MainActor.run(body: { try Self.contextAfterVersionTransition(created.id, appState: appState) }) {
            response["expectedTarget"] = next
        }
        return mcpJSON(response)
    }

    func executeScreenshotsSwitchLocalization(_ args: [String: Any]) async throws -> [String: Any] {
        guard let rawLocale = args["locale"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let locale = rawLocale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locale.isEmpty else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let previousLocale = try await scopedUI {
            let previous = appState.ascManager.selectedScreenshotsLocale
            appState.ascManager.selectedScreenshotsLocale = locale
            return previous
        }

        await appState.ascManager.refreshTabData(.screenshots)

        let availableLocales = try await scopedUI {
            appState.ascManager.localizations.map(\.attributes.locale).sorted()
        }
        guard availableLocales.contains(locale) else {
            try await scopedUI {
                appState.ascManager.selectedScreenshotsLocale = previousLocale
            }
            let availableText = availableLocales.isEmpty ? "none" : availableLocales.joined(separator: ", ")
            return mcpText(
                "Error: screenshot localization '\(locale)' was not found after refreshing from ASC. "
                    + "Available localizations: \(availableText)"
            )
        }

        await appState.ascManager.loadScreenshots(locale: locale, force: true)

        let displayTypes = await screenshotsDisplayTypesForActiveProject()
        let trackCounts = try await scopedUI { () -> [String: Int] in
            var counts: [String: Int] = [:]
            for displayType in displayTypes {
                appState.ascManager.loadTrackFromASC(displayType: displayType, locale: locale)
                counts[displayType] = appState.ascManager
                    .trackSlotsForDisplayType(displayType, locale: locale)
                    .compactMap { $0 }
                    .count
            }
            return counts
        }

        return mcpJSON([
            "success": true,
            "locale": locale,
            "availableLocales": availableLocales,
            "trackCounts": trackCounts
        ])
    }

    private func resolveScreenshotSlotIndex(_ rawValue: Any?) -> Int? {
        guard let slotRaw = rawValue as? Int ?? (rawValue as? Double).map({ Int($0) }),
              slotRaw >= 1 && slotRaw <= 10 else {
            return nil
        }
        return slotRaw - 1
    }

    private func selectedScreenshotsLocale() async -> String? {
        await MainActor.run {
            appState.ascManager.selectedScreenshotsLocale
                ?? appState.ascManager.localizations.first?.attributes.locale
        }
    }

    private func ensurePreparedScreenshotsTrack(
        displayType: String,
        locale: String,
        explicitlyRequestedLocale: Bool
    ) async throws -> String? {
        let selectedLocale = await selectedScreenshotsLocale()
        if explicitlyRequestedLocale, selectedLocale != locale {
            return "Error: screenshots locale '\(locale)' is not selected in Blitz Neo. Call screenshots_switch_localization first."
        }

        try await scopedUI {
            let asc = appState.ascManager
            if !asc.hasTrackState(displayType: displayType, locale: locale),
               selectedLocale == locale {
                asc.loadTrackFromASC(displayType: displayType, locale: locale)
            }
        }

        let trackReady = try await scopedUI {
            appState.ascManager.hasTrackState(displayType: displayType, locale: locale)
        }
        guard trackReady else {
            return "Error: screenshot locale '\(locale)' is not prepared in Blitz Neo. Call screenshots_switch_localization first."
        }
        return nil
    }

    private func decodeScreenshotImage(at url: URL) -> NSImage? {
        if let image = NSImage(contentsOf: url), !image.representations.isEmpty {
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func importScreenshotToProjectStore(
        sourcePath: String,
        fileNameOverride: String?,
        projectId: String
    ) throws -> (storedPath: String, storedFileName: String) {
        let expanded = (sourcePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw NSError(domain: "BlitzMCP", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "file not found at \(expanded)"
            ])
        }

        let sourceURL = URL(fileURLWithPath: expanded)
        let requestedFileName = fileNameOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let normalizedFileName: String
        if let requestedFileName, !requestedFileName.isEmpty {
            if sourceExtension == "png" {
                normalizedFileName = requestedFileName
            } else {
                let baseName = URL(fileURLWithPath: requestedFileName)
                    .deletingPathExtension()
                    .lastPathComponent
                normalizedFileName = baseName + ".png"
            }
        } else if sourceExtension == "png" {
            normalizedFileName = sourceURL.lastPathComponent
        } else {
            normalizedFileName = sourceURL.deletingPathExtension().lastPathComponent + ".png"
        }

        let destDir = BlitzPaths.screenshots(projectId: projectId)
        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destURL = destDir.appendingPathComponent(normalizedFileName)

        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }

        if sourceExtension == "png" {
            try fm.copyItem(at: sourceURL, to: destURL)
        } else {
            guard let image = decodeScreenshotImage(at: sourceURL) else {
                throw NSError(domain: "BlitzMCP", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "unsupported format or could not load image at \(expanded)"
                ])
            }
            guard let pngData = pngData(for: image) else {
                throw NSError(domain: "BlitzMCP", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "failed to convert image to PNG"
                ])
            }
            try pngData.write(to: destURL)
        }

        return (destURL.path, normalizedFileName)
    }

    func executeScreenshotsPutTrackSlot(_ args: [String: Any]) async throws -> [String: Any] {
        guard let sourcePath = args["sourcePath"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        guard let slotIndex = resolveScreenshotSlotIndex(args["slotIndex"]) else {
            return mcpText("Error: slotIndex must be between 1 and 10")
        }
        let slotRaw = slotIndex + 1
        let displayType = args["displayType"] as? String ?? "APP_IPHONE_67"
        let (locale, explicitlyRequestedLocale) = await resolveScreenshotsLocale(from: args)
        if let error = try await ensurePreparedScreenshotsTrack(
            displayType: displayType,
            locale: locale,
            explicitlyRequestedLocale: explicitlyRequestedLocale
        ) {
            return mcpText(error)
        }

        guard let projectId = try await scopedUI(body: { appState.activeProjectId }) else {
            return mcpText("Error: no active project")
        }

        let storedAsset: (storedPath: String, storedFileName: String)
        do {
            storedAsset = try importScreenshotToProjectStore(
                sourcePath: sourcePath,
                fileNameOverride: args["fileName"] as? String,
                projectId: projectId
            )
        } catch {
            return mcpText("Error: \(error.localizedDescription)")
        }

        let error = try await scopedUI {
            appState.ascManager.addAssetToTrack(
                displayType: displayType,
                slotIndex: slotIndex,
                localPath: storedAsset.storedPath,
                locale: locale
            )
        }
        if let error {
            return mcpText("Error: \(error)")
        }
        return mcpJSON([
            "success": true,
            "slot": slotRaw,
            "locale": locale,
            "displayType": displayType,
            "fileName": storedAsset.storedFileName,
        ])
    }

    func executeScreenshotsRemoveTrackSlot(_ args: [String: Any]) async throws -> [String: Any] {
        guard let slotIndex = resolveScreenshotSlotIndex(args["slotIndex"]) else {
            return mcpText("Error: slotIndex must be between 1 and 10")
        }
        let slotRaw = slotIndex + 1
        let displayType = args["displayType"] as? String ?? "APP_IPHONE_67"
        let (locale, explicitlyRequestedLocale) = await resolveScreenshotsLocale(from: args)
        if let error = try await ensurePreparedScreenshotsTrack(
            displayType: displayType,
            locale: locale,
            explicitlyRequestedLocale: explicitlyRequestedLocale
        ) {
            return mcpText(error)
        }

        let slotExists = try await scopedUI {
            appState.ascManager.trackSlotsForDisplayType(displayType, locale: locale)[slotIndex] != nil
        }
        guard slotExists else {
            return mcpText("Error: slot \(slotRaw) is already empty")
        }

        try await scopedUI {
            appState.ascManager.removeFromTrack(
                displayType: displayType,
                slotIndex: slotIndex,
                locale: locale
            )
        }

        return mcpJSON([
            "success": true,
            "slot": slotRaw,
            "locale": locale,
            "displayType": displayType,
        ])
    }

    func executeScreenshotsReorderTrack(_ args: [String: Any]) async throws -> [String: Any] {
        guard let rawOrder = args["order"] as? [Any] else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let order = rawOrder.compactMap { value -> Int? in
            if let intValue = value as? Int {
                return intValue
            }
            if let doubleValue = value as? Double {
                return Int(doubleValue)
            }
            return nil
        }
        guard order.count == rawOrder.count else {
            return mcpText("Error: order must contain only integers")
        }

        let displayType = args["displayType"] as? String ?? "APP_IPHONE_67"
        let (locale, explicitlyRequestedLocale) = await resolveScreenshotsLocale(from: args)
        if let error = try await ensurePreparedScreenshotsTrack(
            displayType: displayType,
            locale: locale,
            explicitlyRequestedLocale: explicitlyRequestedLocale
        ) {
            return mcpText(error)
        }

        if let error = try await scopedUI(body: {
            appState.ascManager.reorderTrack(
                displayType: displayType,
                order: order,
                locale: locale
            )
        }) {
            return mcpText("Error: \(error)")
        }

        return mcpJSON([
            "success": true,
            "order": order,
            "locale": locale,
            "displayType": displayType,
        ])
    }

    func executeScreenshotsSave(_ args: [String: Any]) async throws -> [String: Any] {
        let requestedDisplayType = args["displayType"] as? String
        let (locale, explicitlyRequestedLocale) = await resolveScreenshotsLocale(from: args)
        let projectDisplayTypes = await screenshotsDisplayTypesForActiveProject()

        let selectedLocale = try await scopedUI {
            appState.ascManager.selectedScreenshotsLocale ?? appState.ascManager.localizations.first?.attributes.locale
        }
        if explicitlyRequestedLocale, selectedLocale != locale {
            return mcpText(
                "Error: screenshots locale '\(locale)' is not selected in Blitz Neo. "
                    + "Call screenshots_switch_localization first."
            )
        }

        let displayTypes = try await scopedUI {
            Self.screenshotSaveDisplayTypes(
                requestedDisplayType: requestedDisplayType,
                locale: locale,
                projectDisplayTypes: projectDisplayTypes,
                asc: appState.ascManager
            )
        }

        var syncedTracks: [[String: Any]] = []
        var hadChanges = false
        var preparedTrackCount = 0

        for displayType in displayTypes {
            try await scopedUI {
                let asc = appState.ascManager
                if !asc.hasTrackState(displayType: displayType, locale: locale),
                   selectedLocale == locale {
                    asc.loadTrackFromASC(displayType: displayType, locale: locale)
                }
            }

            let trackReady = try await scopedUI {
                appState.ascManager.hasTrackState(displayType: displayType, locale: locale)
            }
            if !trackReady {
                if requestedDisplayType != nil {
                    return mcpText(
                        "Error: screenshot locale '\(locale)' is not prepared in Blitz Neo. "
                            + "Call screenshots_switch_localization first."
                    )
                }
                continue
            }
            preparedTrackCount += 1

            let trackHasChanges = try await scopedUI {
                appState.ascManager.hasUnsavedChanges(displayType: displayType, locale: locale)
            }
            if !trackHasChanges {
                continue
            }

            hadChanges = true
            try await MCPMutationScope.checkBeforeWrite()
            await appState.ascManager.syncTrackToASC(displayType: displayType, locale: locale)

            if let err = await checkASCWriteError(tab: "screenshots") { return err }

            let slotCount = try await scopedUI {
                appState.ascManager.trackSlotsForDisplayType(displayType, locale: locale).compactMap { $0 }.count
            }
            syncedTracks.append([
                "displayType": displayType,
                "synced": slotCount,
            ])
        }

        guard preparedTrackCount > 0 else {
            return mcpText(
                "Error: screenshot locale '\(locale)' is not prepared in Blitz Neo. "
                    + "Call screenshots_switch_localization first."
            )
        }

        guard hadChanges else {
            return mcpJSON([
                "success": true,
                "message": "No changes to save",
                "locale": locale,
                "displayTypes": displayTypes,
            ])
        }

        let totalSynced = syncedTracks.reduce(0) { partialResult, entry in
            partialResult + (entry["synced"] as? Int ?? 0)
        }
        return mcpJSON([
            "success": true,
            "synced": totalSynced,
            "locale": locale,
            "tracks": syncedTracks,
        ])
    }

    func executeASCOpenSubmitPreview() async -> [String: Any] {
        guard let target = await MainActor.run(body: { () -> ASCReleaseOperationTarget? in
            guard Self.releaseApprovalTargetMatches(appState) else { return nil }
            return appState.ascManager.releaseOperationTarget()
        }) else { return mcpText("Error: no unchanged app is selected.") }
        await appState.ascManager.syncOverviewSubmissionReadiness(forceRefresh: true)
        let response = await MainActor.run { () -> [String: Any]? in
            let asc = appState.ascManager
            guard target.matches(asc), !Task.isCancelled else { return nil }
            guard asc.selectedVersion != nil else {
                return ["ready": false, "missing": ["App Store Version"], "canCreateUpdate": true]
            }
            // A preview is read-only. A matching build can be chosen in the sheet;
            // only the explicit submit action attaches it.
            asc.showSubmitPreview = true
            return ["ready": asc.submissionReadiness.isComplete, "opened": true,
                "statusOnly": !asc.selectedVersionIsEditable,
                "missing": asc.submissionReadiness.missingRequired.map(\.label)]
        }
        guard let response else { return mcpText("Error: app or version changed while preparing the preview.") }
        return mcpJSON(response)
    }

    // MARK: - ASC IAP / Subscriptions / Pricing Tools

    static func priceMatches(_ customerPrice: String?, target: String) -> Bool {
        guard let customerPrice else { return false }
        guard let a = Double(customerPrice), let b = Double(target) else {
            return customerPrice == target
        }
        return abs(a - b) < 0.001
    }

    func executeASCWebAuth() async -> [String: Any] {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }

        guard let session = await appState.ascManager.requestWebAuthForMCP() else {
            let authError = await MainActor.run { appState.ascManager.irisFeedbackError }
            if let authError, !authError.isEmpty {
                return mcpJSON([
                    "success": false,
                    "cancelled": false,
                    "message": authError
                ])
            }
            return mcpJSON([
                "success": false,
                "cancelled": true,
                "message": "Web authentication was cancelled before a session was captured."
            ])
        }

        let email = session.email ?? "unknown"
        return mcpJSON([
            "success": true,
            "email": email,
            "message": "Web session authenticated and synced to ~/.blitz/asc-agent/web-session.json. This renews authentication only, not the app-creation operation. Before continuing an app creation, compare get_tab_state appCreationSetup with the original confirmed identity and account. Only a proven account_verification/401 with creationAttempted=false permits the skill's one guarded --resume-after-auth continuation."
        ])
    }

    func executeASCSetAppPrice(_ args: [String: Any]) async throws -> [String: Any] {
        guard let priceStr = args["price"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let effectiveDate = args["effectiveDate"] as? String

        guard let service = try await scopedUI(body: { appState.ascManager.service }) else {
            return mcpText("Error: ASC service not configured")
        }
        guard let appId = try await scopedUI(body: { appState.ascManager.app?.id }) else {
            return mcpText("Error: no ASC app loaded. Open a project with a bundle ID first.")
        }

        if let priceVal = Double(priceStr), priceVal < 0.001 {
            let startedAt = Date()
            do {
                try await service.setPriceFree(appId: appId)
                try await service.ensureAppAvailability(appId: appId)
                try await scopedUI {
                    appState.ascManager.currentAppPricePointId = appState.ascManager.freeAppPricePointId
                    appState.ascManager.scheduledAppPricePointId = nil
                    appState.ascManager.scheduledAppPriceEffectiveDate = nil
                    appState.ascManager.monetizationStatus = "Free"
                }
                await appState.ascManager.refreshTabData(.monetization)
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_price.free",
                    success: true,
                    startedAt: startedAt
                )
                return mcpJSON([
                    "success": true,
                    "price": "0.00",
                    "message": "App set to free with territory availability configured"
                ])
            } catch {
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_price.free",
                    success: false,
                    startedAt: startedAt
                )
                throw error
            }
        }

        let commandType = effectiveDate == nil ? "app_price.set" : "app_price.schedule"
        let startedAt = Date()

        do {
            let pricePoints = try await service.fetchAppPricePoints(appId: appId)
            guard let match = pricePoints.first(where: {
                Self.priceMatches($0.attributes.customerPrice, target: priceStr)
            }) else {
                let sorted = pricePoints.compactMap { $0.attributes.customerPrice }
                    .compactMap { Double($0) }
                    .filter { $0 > 0 }
                    .sorted()
                let samples = sorted.count <= 30 ? sorted : {
                    let lo = Array(sorted.prefix(5))
                    let hi = Array(sorted.suffix(5))
                    let step = max(1, (sorted.count - 10) / 10)
                    let mid = stride(from: 5, to: sorted.count - 5, by: step).map { sorted[$0] }
                    return lo + mid + hi
                }()
                let formatted = samples.map { String(format: "%.2f", $0) }
                return mcpText(
                    "Error: no price point matching $\(priceStr). \(sorted.count) tiers available, "
                        + "samples: \(formatted.joined(separator: ", "))"
                )
            }

            if let effectiveDate {
                let freePoint = pricePoints.first(where: {
                    let p = $0.attributes.customerPrice ?? "0"
                    return p == "0" || p == "0.0" || p == "0.00"
                })
                let currentId = freePoint?.id ?? match.id
                try await service.setScheduledAppPrice(
                    appId: appId,
                    currentPricePointId: currentId,
                    futurePricePointId: match.id,
                    effectiveDate: effectiveDate
                )
                try await service.ensureAppAvailability(appId: appId)
                try await scopedUI {
                    appState.ascManager.currentAppPricePointId = currentId
                    appState.ascManager.scheduledAppPricePointId = match.id
                    appState.ascManager.scheduledAppPriceEffectiveDate = effectiveDate
                    appState.ascManager.monetizationStatus = "Configured"
                }
                await appState.ascManager.refreshTabData(.monetization)
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: commandType,
                    success: true,
                    startedAt: startedAt
                )
                return mcpJSON([
                    "success": true,
                    "price": priceStr,
                    "effectiveDate": effectiveDate,
                    "message": "Scheduled price change for \(effectiveDate) with territory availability configured"
                ])
            }

            try await service.setAppPrice(appId: appId, pricePointId: match.id)
            try await service.ensureAppAvailability(appId: appId)
            try await scopedUI {
                appState.ascManager.currentAppPricePointId = match.id
                appState.ascManager.scheduledAppPricePointId = nil
                appState.ascManager.scheduledAppPriceEffectiveDate = nil
                appState.ascManager.monetizationStatus = "Configured"
            }
            await appState.ascManager.refreshTabData(.monetization)
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: commandType,
                success: true,
                startedAt: startedAt
            )
            return mcpJSON(["success": true, "price": priceStr, "pricePointId": match.id])
        } catch {
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: commandType,
                success: false,
                startedAt: startedAt
            )
            throw error
        }
    }

    func executeASCCreateIAP(_ args: [String: Any]) async throws -> [String: Any] {
        guard let productId = args["productId"] as? String,
              let name = args["name"] as? String,
              let type = args["type"] as? String,
              let displayName = args["displayName"] as? String,
              let priceStr = args["price"] as? String,
              let screenshotPath = args["screenshotPath"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let description = args["description"] as? String

        let validTypes = ["CONSUMABLE", "NON_CONSUMABLE", "NON_RENEWING_SUBSCRIPTION"]
        guard validTypes.contains(type) else {
            return mcpText("Error: invalid type '\(type)'. Must be one of: \(validTypes.joined(separator: ", "))")
        }

        try await scopedUI {
            var values: [String: String] = [
                "kind": "iap",
                "name": name,
                "productId": productId,
                "type": type,
                "displayName": displayName,
                "price": priceStr
            ]
            if let description { values["description"] = description }
            appState.ascManager.pendingCreateValues = values
        }

        try await scopedUI {
            appState.ascManager.createIAP(
                name: name,
                productId: productId,
                type: type,
                displayName: displayName,
                description: description,
                price: priceStr,
                screenshotPath: screenshotPath
            )
        }

        if let error = await pollASCCreation() {
            return mcpText("Error creating IAP: \(error)")
        }

        return mcpJSON([
            "success": true,
            "productId": productId,
            "type": type,
            "displayName": displayName,
            "price": priceStr
        ])
    }

    func executeASCCreateSubscription(_ args: [String: Any]) async throws -> [String: Any] {
        guard let groupName = args["groupName"] as? String,
              let productId = args["productId"] as? String,
              let name = args["name"] as? String,
              let displayName = args["displayName"] as? String,
              let duration = args["duration"] as? String,
              let priceStr = args["price"] as? String,
              let screenshotPath = args["screenshotPath"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let description = args["description"] as? String

        let validDurations = ["ONE_WEEK", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS", "SIX_MONTHS", "ONE_YEAR"]
        guard validDurations.contains(duration) else {
            return mcpText(
                "Error: invalid duration '\(duration)'. Must be one of: \(validDurations.joined(separator: ", "))"
            )
        }

        try await scopedUI {
            var values: [String: String] = [
                "kind": "subscription",
                "groupName": groupName,
                "name": name,
                "productId": productId,
                "displayName": displayName,
                "duration": duration,
                "price": priceStr
            ]
            if let description { values["description"] = description }
            appState.ascManager.pendingCreateValues = values
        }

        try await scopedUI {
            appState.ascManager.createSubscription(
                groupName: groupName,
                name: name,
                productId: productId,
                displayName: displayName,
                description: description,
                duration: duration,
                price: priceStr,
                screenshotPath: screenshotPath
            )
        }

        if let error = await pollASCCreation() {
            return mcpText("Error creating subscription: \(error)")
        }

        return mcpJSON([
            "success": true,
            "groupName": groupName,
            "productId": productId,
            "displayName": displayName,
            "duration": duration,
            "price": priceStr
        ])
    }

    func pollASCCreation() async -> String? {
        for _ in 0..<10 {
            do { try await MCPMutationScope.checkBeforeWrite() }
            catch { return error.localizedDescription }
            let creating = await MainActor.run { appState.ascManager.isCreating }
            if creating { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        while await MainActor.run(body: { appState.ascManager.isCreating }) {
            do { try await MCPMutationScope.checkBeforeWrite() }
            catch { return error.localizedDescription }
            try? await Task.sleep(for: .milliseconds(500))
        }
        do { try await MCPMutationScope.checkBeforeWrite() }
        catch { return error.localizedDescription }
        return await MainActor.run { appState.ascManager.writeError }
    }

    func executeGetRejectionFeedback(_ args: [String: Any]) async throws -> [String: Any] {
        let raw = await MainActor.run { () -> [String: Any] in
            let asc = appState.ascManager
            guard let appId = asc.app?.id else {
                return ["error": "No app connected. Set up ASC credentials first."]
            }

            let requestedVersion = args["version"] as? String
            let version: String
            if let requestedVersion {
                version = requestedVersion
            } else if let rejected = asc.releaseVersions.first(where: {
                let state = ($0.attributes.appStoreState ?? "").uppercased()
                return state == "REJECTED" || state == "METADATA_REJECTED"
            }) {
                version = rejected.attributes.versionString
            } else {
                return ["error": "No rejected version found.", "appId": appId]
            }

            asc.loadCachedFeedback(appId: appId, versionString: version)
            let cycles = asc.feedbackCycles(forVersionString: version)
            if !cycles.isEmpty {
                let payload = cycles.map { cycle -> [String: Any] in
                    let reasons = cycle.reasons.map { reason in
                        ["section": reason.section, "description": reason.description, "code": reason.code]
                    }
                    let messages = cycle.messages.map { message -> [String: String] in
                        var msg = ["body": message.body]
                        if let date = message.createdAt { msg["date"] = date }
                        return msg
                    }
                    return [
                        "id": cycle.id,
                        "version": cycle.versionString ?? version,
                        "submissionId": cycle.submissionId ?? "",
                        "occurredAt": cycle.occurredAt,
                        "source": cycle.source,
                        "reasons": reasons,
                        "messages": messages
                    ]
                }
                return [
                    "appId": appId,
                    "version": version,
                    "cycles": payload,
                    "source": "archive"
                ]
            }

            return [
                "error": "No rejection feedback cached for version \(version). The user needs to sign in with their Apple ID in the ASC Overview tab to fetch feedback.",
                "appId": appId,
                "version": version
            ]
        }
        return mcpJSON(raw)
    }
}
