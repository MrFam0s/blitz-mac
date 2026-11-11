import Foundation

extension MCPExecutor {
    @MainActor
    static func appCreationSetupState(_ asc: ASCManager) -> [String: Any]? {
        guard asc.app == nil else { return nil }
        let context: ASCManager.PendingBundleIDSetupContext
        let phase: String
        let canReopen: Bool
        if let request = asc.activeAppCreationFormRequest {
            context = request.context
            phase = "identityForm"
            canReopen = false
        } else if let pending = asc.pendingBundleIDSetup,
                  (try? asc.validateBundleIDSetupContext(pending)) != nil {
            context = pending
            phase = pending.registrationComplete ? "awaitingAppCreation" : "registeringBundleID"
            canReopen = pending.registrationComplete
        } else { return nil }
        var state: [String: Any] = ["projectId": context.projectId, "phase": phase,
            "canReopenForm": canReopen, "requiresNewConfirmation": phase == "identityForm",
            "identity": ["appName": context.identity.appName, "bundleId": context.identity.bundleId,
                "sku": context.identity.sku, "platform": context.identity.platform.rawValue,
                "primaryLocale": context.identity.primaryLocale]]
        // Reopened forms must not advertise their invalidated operation as usable.
        if phase != "identityForm" {
            state["operationId"] = context.operationId.uuidString
            // Non-secret API account identifiers bind a renewed web login to
            // the same confirmed operation; they are not session credentials.
            state["expectedIssuerId"] = context.expectedIssuerId
            state["expectedKeyId"] = context.expectedKeyId
        }
        return state
    }

    /// Explicit caller identity is required even for obtaining a writable context.
    /// This never opens a project or adopts a different selected version silently.
    func executeGetReleaseContext(_ args: [String: Any]) async -> [String: Any] {
        guard let projectId = args["projectId"] as? String, !projectId.isEmpty,
              let appId = args["appId"] as? String, !appId.isEmpty else {
            return mcpText("Error: projectId and appId are required; use project_list and the intended app's documented Store ID.")
        }
        do {
            let expected = try await MainActor.run { () throws -> MCPExpectedTarget in
                let captured = MCPReleaseRequestTarget.capture(appState)
                guard captured.projectID == projectId, captured.appID == appId,
                      appState.ascManager.loadedProjectId == projectId,
                      appState.ascManager.app?.bundleId == captured.bundleID else {
                    throw MCPBoundRequestError.targetChanged
                }
                if args.keys.contains("versionId") {
                    let version = args["versionId"] as? String
                    guard (args["versionId"] is NSNull || version?.isEmpty == false),
                          version == captured.selectedVersionID else { throw MCPBoundRequestError.targetChanged }
                }
                return try MCPExpectedTarget(captured: captured)
            }
            return mcpJSON(["success": true, "expectedTarget": expected.json,
                "note": "This verifies the current local target, not Apple readiness or authorization to publish. Re-read after a version change."])
        } catch { return mcpText("Error: \(error.localizedDescription)") }
    }

    // MARK: - Tab State Tool

    private static let ageRatingBooleanFieldReaders: [(String, (ASCAgeRatingDeclaration.Attributes) -> Bool?)] = [
        ("gambling", { $0.gambling }),
        ("messagingAndChat", { $0.messagingAndChat }),
        ("unrestrictedWebAccess", { $0.unrestrictedWebAccess }),
        ("userGeneratedContent", { $0.userGeneratedContent }),
        ("advertising", { $0.advertising }),
        ("lootBox", { $0.lootBox }),
        ("healthOrWellnessTopics", { $0.healthOrWellnessTopics }),
        ("parentalControls", { $0.parentalControls }),
        ("ageAssurance", { $0.ageAssurance }),
    ]

    private static let ageRatingEnumFieldReaders: [(String, (ASCAgeRatingDeclaration.Attributes) -> String?)] = [
        ("alcoholTobaccoOrDrugUseOrReferences", { $0.alcoholTobaccoOrDrugUseOrReferences }),
        ("contests", { $0.contests }),
        ("gamblingSimulated", { $0.gamblingSimulated }),
        ("gunsOrOtherWeapons", { $0.gunsOrOtherWeapons }),
        ("horrorOrFearThemes", { $0.horrorOrFearThemes }),
        ("matureOrSuggestiveThemes", { $0.matureOrSuggestiveThemes }),
        ("medicalOrTreatmentInformation", { $0.medicalOrTreatmentInformation }),
        ("profanityOrCrudeHumor", { $0.profanityOrCrudeHumor }),
        ("sexualContentGraphicAndNudity", { $0.sexualContentGraphicAndNudity }),
        ("sexualContentOrNudity", { $0.sexualContentOrNudity }),
        ("violenceCartoonOrFantasy", { $0.violenceCartoonOrFantasy }),
        ("violenceRealistic", { $0.violenceRealistic }),
        ("violenceRealisticProlongedGraphicOrSadistic", { $0.violenceRealisticProlongedGraphicOrSadistic }),
    ]

    private static let reviewContactFieldOrder = [
        "contactFirstName",
        "contactLastName",
        "contactEmail",
        "contactPhone",
        "notes",
        "demoAccountRequired",
        "demoAccountName",
        "demoAccountPassword",
    ]

    private static func overviewReviewDraftKey(for label: String) -> String? {
        switch label {
        case "Review Contact First Name":
            return "contactFirstName"
        case "Review Contact Last Name":
            return "contactLastName"
        case "Review Contact Email":
            return "contactEmail"
        case "Review Contact Phone":
            return "contactPhone"
        case "Demo Account Name":
            return "demoAccountName"
        case "Demo Account Password":
            return "demoAccountPassword"
        default:
            return nil
        }
    }

    static func ageRatingStatePayload(
        ageRating: ASCAgeRatingDeclaration?,
        isSaved: Bool,
        pendingDraft: [String: String]?
    ) -> [String: Any]? {
        let hasPendingDraft = !(pendingDraft?.isEmpty ?? true)
        guard ageRating != nil || hasPendingDraft else { return nil }

        let attributes = ageRating?.attributes
        var payload: [String: Any] = [
            "isSaved": isSaved,
            "hasPendingChanges": hasPendingDraft,
        ]
        if let ageRating {
            payload["id"] = ageRating.id
        }

        var missingRequired: [String] = []
        for (field, reader) in ageRatingBooleanFieldReaders {
            if let attributes, let value = reader(attributes) {
                payload[field] = value
            } else {
                payload[field] = NSNull()
                missingRequired.append(field)
            }
        }
        for (field, reader) in ageRatingEnumFieldReaders {
            if let attributes, let value = reader(attributes), !value.isEmpty {
                payload[field] = value
            } else {
                payload[field] = NSNull()
                missingRequired.append(field)
            }
        }

        payload["missingRequired"] = missingRequired
        if let pendingDraft, !pendingDraft.isEmpty {
            payload["draftValues"] = pendingDraft
        }
        return payload
    }

    static func reviewContactFieldPayload(from attributes: [String: Any]) -> [String: Any] {
        var payload: [String: Any] = [:]
        for field in reviewContactFieldOrder {
            if field == "demoAccountRequired" {
                payload[field] = attributes[field] as? Bool ?? false
            } else {
                payload[field] = reviewContactStringValue(attributes[field]) ?? ""
            }
        }
        return payload
    }

    static func reviewContactStatePayload(
        reviewDetail: ASCReviewDetail?,
        pendingDraft: [String: String]?
    ) -> [String: Any]? {
        let hasPendingDraft = !(pendingDraft?.isEmpty ?? true)
        guard reviewDetail != nil || hasPendingDraft else { return nil }

        let persisted = mergedReviewContactAttributes(reviewDetail: reviewDetail, draft: [:])
        let effective = mergedReviewContactAttributes(reviewDetail: reviewDetail, draft: pendingDraft ?? [:])
        let persistedMissingRequired = missingRequiredReviewContactFields(from: persisted)

        var payload = reviewContactFieldPayload(from: effective)
        payload["savedToASC"] = !hasPendingDraft
        payload["hasPendingChanges"] = hasPendingDraft
        payload["missingRequired"] = missingRequiredReviewContactFields(from: effective)
        payload["missingRequiredPersisted"] = persistedMissingRequired
        if let reviewDetail {
            payload["id"] = reviewDetail.id
        }
        payload["persisted"] = reviewContactFieldPayload(from: persisted)
        if let pendingDraft, !pendingDraft.isEmpty {
            payload["pendingDraft"] = pendingDraft
        }
        return payload
    }

    static func overviewSubmissionReadinessPayload(
        readiness: SubmissionReadiness,
        reviewDetail: ASCReviewDetail?,
        pendingFormValues: [String: [String: String]]
    ) -> [String: Any] {
        let pendingReviewDraft = pendingFormValues["review.contact"] ?? [:]
        let effectiveReviewContact = mergedReviewContactAttributes(
            reviewDetail: reviewDetail,
            draft: pendingReviewDraft
        )
        let effectiveDemoRequired = effectiveReviewContact["demoAccountRequired"] as? Bool == true

        var effectiveFields = readiness.fields
        if effectiveDemoRequired {
            let existingLabels = Set(effectiveFields.map(\.label))
            if !existingLabels.contains("Demo Account Name") {
                effectiveFields.append(.init(label: "Demo Account Name", value: nil))
            }
            if !existingLabels.contains("Demo Account Password") {
                effectiveFields.append(.init(label: "Demo Account Password", value: nil))
            }
        }

        var fieldEntries: [[String: Any]] = []
        var missingRequiredConsideringDrafts: [String] = []

        for field in effectiveFields {
            let draftKey = overviewReviewDraftKey(for: field.label)
            let hasPendingChange = draftKey.map { pendingReviewDraft[$0] != nil } ?? false
            let effectiveValue: String?
            if let draftKey, let value = reviewContactStringValue(effectiveReviewContact[draftKey]) {
                effectiveValue = value
            } else {
                effectiveValue = field.value
            }

            let persistedFilled = field.value != nil && !(field.value?.isEmpty ?? true)
            let effectiveFilled = effectiveValue != nil && !(effectiveValue?.isEmpty ?? true)
            if field.required && !field.isLoading && !field.loadFailed && !effectiveFilled {
                missingRequiredConsideringDrafts.append(field.label)
            }

            var entry: [String: Any] = [
                "label": field.label,
                "value": effectiveValue ?? NSNull(),
                "required": field.required,
                "filled": persistedFilled,
                "isLoading": field.isLoading,
                "loadFailed": field.loadFailed,
                "savedToASC": !hasPendingChange,
            ]
            if hasPendingChange {
                entry["source"] = "draft"
                entry["hasPendingChanges"] = true
                entry["persistedValue"] = field.value ?? NSNull()
                entry["filledConsideringDrafts"] = effectiveFilled
            }
            if let hint = field.hint {
                entry["hint"] = hint
            }
            fieldEntries.append(entry)
        }

        let missingRequiredPersisted = readiness.missingRequired.map(\.label)

        return [
            "isComplete": readiness.isComplete,
            "isCompleteConsideringDrafts": missingRequiredConsideringDrafts.isEmpty
                && !readiness.fields.contains { $0.required && ($0.isLoading || $0.loadFailed) },
            "fields": fieldEntries,
            "missingRequired": missingRequiredPersisted,
            "missingRequiredPersisted": missingRequiredPersisted,
            "missingRequiredConsideringDrafts": missingRequiredConsideringDrafts,
            "hasPendingDrafts": !pendingFormValues.isEmpty,
        ]
    }

    /// Apple version workflow states do not establish availability on the storefront.
    static func versionStatePayload(_ version: ASCAppStoreVersion?) -> [String: Any]? {
        guard let version else { return nil }
        var payload: [String: Any] = [
            "id": version.id,
            "versionString": version.attributes.versionString,
            "state": version.attributes.effectiveState ?? "unknown",
            "stateKind": "appleVersionWorkflow",
        ]
        if let state = version.attributes.appVersionState {
            payload["appVersionState"] = state
        }
        if let state = version.attributes.appStoreState {
            payload["appStoreState"] = state
        }
        if let createdDate = version.attributes.createdDate {
            payload["createdDate"] = createdDate
        }
        if let releaseType = version.attributes.releaseType {
            payload["releaseType"] = releaseType
        }
        return payload
    }

    /// Only current, successful evidence may carry a checked-at timestamp.
    static func storeAvailabilityStatePayload(
        confirmed: ASCStoreAvailability?,
        isLoading: Bool,
        failed: Bool,
        checkedAt: Date?
    ) -> [String: Any] {
        let state = isLoading ? "checking" : (failed ? "unknown" : confirmed?.rawValue ?? "unknown")
        var payload: [String: Any] = ["state": state, "error": failed]
        if !isLoading, !failed, confirmed != nil,
           let checkedAt, checkedAt.timeIntervalSinceReferenceDate.isFinite {
            payload["checkedAt"] = ISO8601DateFormatter().string(from: checkedAt)
        }
        return payload
    }

    @MainActor
    static func tabStateHeader(for tab: AppTab, asc: ASCManager) -> [String: Any] {
        [
            "tab": tab.rawValue,
            "isLoading": asc.isTabLoading(tab),
            "dataLoaded": asc.loadedTabs.contains(tab),
            "needsRefresh": asc.tabsNeedingRevalidation.contains(tab) || asc.tabError[tab] != nil,
            "storeAvailability": storeAvailabilityStatePayload(
                confirmed: asc.confirmedStoreAvailability,
                isLoading: asc.isStoreAvailabilityLoading,
                failed: asc.storeAvailabilityFailed,
                checkedAt: asc.storeAvailabilityUpdatedAt
            ),
        ]
    }

    func executeGetTabState(_ args: [String: Any]) async throws -> [String: Any] {
        let tab: AppTab
        if let requested = args["tab"] as? String {
            if requested == "ascOverview" || requested == "overview" { tab = .app }
            else if let parsed = MCPAppInformationCompatibility.resolveAppTab(requested) { tab = parsed }
            else { return mcpText("Error: unknown tab \(requested).") }
        } else { tab = await MainActor.run { appState.activeTab } }
        let buildID = (args["buildId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = (args["groupId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard buildID == nil || (tab == .builds && buildID?.isEmpty == false),
              groupID == nil || (tab == .groups && groupID?.isEmpty == false) else {
            return mcpText("Error: buildId requires the builds tab; groupId requires the groups tab. IDs must not be empty.")
        }
        return mcpJSON(await readTabState(tab, buildID: buildID, groupID: groupID))
    }

    @MainActor
    private func readTabState(_ tab: AppTab, buildID: String?, groupID: String?) async -> [String: Any] {
        let asc = appState.ascManager
        let target = ASCTabReadTarget(asc)
        let projectID = appState.activeProjectId
        if tab == .app { await asc.syncOverviewSubmissionReadiness(forceRefresh: true) }
        else if [.builds, .groups, .betaInfo, .feedback].contains(tab) { await asc.ensureTabData(tab) }
        guard target.matches(asc), projectID == appState.activeProjectId else {
            return ["success": false, "error": "The app or account changed while loading tab data. Read the intended app again."]
        }
        let detailBuildID = tab == .builds ? (buildID ?? asc.selectedTestFlightBuildId) : nil
        let detailGroupID = tab == .groups ? (groupID ?? asc.selectedTestFlightGroupId) : nil
        if let detailBuildID { _ = await asc.refreshTestFlightBuildDetail(buildId: detailBuildID, force: false) }
        if let detailGroupID { _ = await asc.refreshTestFlightGroupDetail(groupId: detailGroupID, force: false) }
        guard target.matches(asc), projectID == appState.activeProjectId else {
            return ["success": false, "error": "The app or account changed while loading TestFlight relationships. Read the intended app again."]
        }
        // Header and payload are captured in one actor turn, so IDs cannot refer to different apps.
        var result = Self.tabStateHeader(for: tab, asc: asc)
        if tab.isASCTab || tab == .app, let setup = Self.appCreationSetupState(asc) {
            result["appCreationSetup"] = setup
        }
        if let date = asc.tabLoadedAt[tab] { result["loadedAt"] = ISO8601DateFormatter().string(from: date) }
        if let error = asc.tabError[tab] { result["error"] = error }
        if let error = asc.writeError { result["writeError"] = error }
        if tab.isASCTab, let app = asc.app {
            result["app"] = ["id": app.id, "name": app.name, "bundleId": app.bundleId]
        }
        result.merge(tabStateData(for: tab, asc: asc, projectId: projectID)) { _, new in new }
        if let detailBuildID { result.merge(testFlightBuildDetailState(asc, id: detailBuildID)) { _, new in new } }
        if let detailGroupID { result.merge(testFlightGroupDetailState(asc, id: detailGroupID)) { _, new in new } }
        return result
    }

    /// Extract tab-specific state data. Must be called on MainActor.
    @MainActor
    func tabStateData(for tab: AppTab, asc: ASCManager, projectId: String?) -> [String: Any] {
        switch tab {
        case .app:
            if let projectId {
                asc.refreshAppIconStatusIfNeeded(for: projectId)
            }
            return Self.tabStateASCOverview(asc)
        case .appInformation:
            return tabStateAppInformation(asc, projectId: projectId)
        case .review:
            return tabStateReview(asc)
        case .screenshots:
            return tabStateScreenshots(asc)
        case .reviews:
            return tabStateReviews(asc)
        case .builds:
            return tabStateBuilds(asc)
        case .groups:
            return tabStateGroups(asc)
        case .betaInfo:
            return tabStateBetaInfo(asc)
        case .feedback:
            return tabStateFeedback(asc)
        default:
            return ["note": "No structured state available for this tab"]
        }
    }

    @MainActor
    static func tabStateASCOverview(_ asc: ASCManager) -> [String: Any] {
        let readiness = asc.submissionReadiness
        var result: [String: Any] = [
            "submissionReadiness": Self.overviewSubmissionReadinessPayload(
                readiness: readiness,
                reviewDetail: asc.reviewDetail,
                pendingFormValues: asc.pendingFormValues
            ),
            "totalVersions": asc.appStoreVersions.count,
            "isSubmitting": asc.isSubmitting,
            "canCreateUpdate": asc.canCreateUpdate,
            "selectedVersionIsEditable": asc.selectedVersionIsEditable,
        ]
        if let latestVersion = Self.versionStatePayload(asc.appStoreVersions.first) {
            result["latestVersion"] = latestVersion
        }
        if let selectedVersion = Self.versionStatePayload(asc.selectedVersion) {
            result["selectedVersion"] = selectedVersion
        }
        if let liveVersion = Self.versionStatePayload(asc.storeLiveVersion) {
            result["liveVersion"] = liveVersion
        }
        if let distributionReadyVersion = Self.versionStatePayload(asc.distributionReadyVersion) {
            result["distributionReadyVersion"] = distributionReadyVersion
        }
        if let currentUpdateVersion = Self.versionStatePayload(asc.currentUpdateVersion) {
            result["currentUpdateVersion"] = currentUpdateVersion
        }
        if let editableVersion = Self.versionStatePayload(asc.editableVersion) {
            result["editableVersion"] = editableVersion
        }
        if let selectedBuild = asc.selectedVersionBuild {
            result["selectedVersionBuild"] = [
                "id": selectedBuild.id,
                "version": selectedBuild.attributes.version,
                "processingState": selectedBuild.attributes.processingState ?? "unknown",
                "uploadedDate": selectedBuild.attributes.uploadedDate ?? "",
            ]
        }
        if let error = asc.submissionError {
            result["submissionError"] = error
        }
        if let cycle = asc.latestFeedbackCycle(forVersionString: nil) {
            result["rejectionFeedback"] = [
                "version": cycle.versionString ?? "",
                "reasonCount": cycle.reasons.count,
                "messageCount": cycle.messages.count,
                "cycleCount": asc.irisFeedbackCycles.count,
                "hint": "Use get_rejection_feedback tool for full details"
            ]
        }
        return result
    }

    @MainActor
    func tabStateAppInformation(_ asc: ASCManager, projectId: String?) -> [String: Any] {
        let selectedLocale = asc.activeAppInformationLocale() ?? ""
        let localization = asc.appInformationLocalization(locale: selectedLocale)
        let infoLoc = asc.appInfoLocalizationForLocale(selectedLocale)
        let localizationState: [String: Any] = [
            "locale": localization?.attributes.locale ?? "",
            "name": infoLoc?.attributes.name ?? localization?.attributes.title ?? "",
            "subtitle": infoLoc?.attributes.subtitle ?? localization?.attributes.subtitle ?? "",
            "description": localization?.attributes.description ?? "",
            "keywords": localization?.attributes.keywords ?? "",
            "promotionalText": localization?.attributes.promotionalText ?? "",
            "marketingUrl": localization?.attributes.marketingUrl ?? "",
            "supportUrl": localization?.attributes.supportUrl ?? "",
            "whatsNew": localization?.attributes.whatsNew ?? "",
            "privacyPolicyUrl": infoLoc?.attributes.privacyPolicyUrl ?? "",
        ]
        let detailsState: [String: Any] = [
            "copyright": asc.selectedVersion?.attributes.copyright ?? "",
            "primaryCategory": asc.appInfo?.primaryCategoryId ?? "",
            "contentRightsDeclaration": asc.app?.contentRightsDeclaration ?? "",
        ]

        var result: [String: Any] = [
            "selectedLocale": selectedLocale,
            "availableLocales": asc.localizations.map(\.attributes.locale),
            "localization": localizationState,
            "privacyPolicyUrl": infoLoc?.attributes.privacyPolicyUrl ?? "",
            "details": detailsState,
            "appInfo": [
                "primaryCategory": detailsState["primaryCategory"] ?? "",
                "contentRightsDeclaration": detailsState["contentRightsDeclaration"] ?? "",
            ],
            "hasAppInfoLocalization": infoLoc != nil,
            "localeCount": asc.localizations.count,
            "versionCount": asc.appStoreVersions.count,
            "canCreateUpdate": asc.canCreateUpdate,
        ]
        if let projectId {
            let metadata = ProjectStorage().readMetadata(projectId: projectId)
            result["teamId"] = metadata?.teamId ?? ""
        }
        if let latestVersion = Self.versionStatePayload(asc.appStoreVersions.first) {
            result["latestVersion"] = latestVersion
        }
        if let selectedVersion = Self.versionStatePayload(asc.selectedVersion) {
            result["selectedVersion"] = selectedVersion
        }
        return result
    }

    @MainActor
    func tabStateReview(_ asc: ASCManager) -> [String: Any] {
        var result: [String: Any] = [:]

        if let ageRating = Self.ageRatingStatePayload(
            ageRating: asc.ageRatingDeclaration,
            isSaved: asc.ageRatingIsConfigured,
            pendingDraft: asc.pendingFormValues["review.ageRating"]
        ) {
            result["ageRating"] = ageRating
        }

        if let reviewContact = Self.reviewContactStatePayload(
            reviewDetail: asc.reviewDetail,
            pendingDraft: asc.pendingFormValues["review.contact"]
        ) {
            result["reviewContact"] = reviewContact
        }

        result["builds"] = asc.builds.prefix(10).map { build -> [String: Any] in
            [
                "id": build.id,
                "version": build.attributes.version,
                "processingState": build.attributes.processingState ?? "unknown",
                "uploadedDate": build.attributes.uploadedDate ?? ""
            ]
        }
        result["canCreateUpdate"] = asc.canCreateUpdate
        if let selectedVersion = Self.versionStatePayload(asc.selectedVersion) {
            result["selectedVersion"] = selectedVersion
        }
        if let selectedBuild = asc.selectedVersionBuild {
            result["selectedVersionBuild"] = [
                "id": selectedBuild.id,
                "version": selectedBuild.attributes.version,
                "processingState": selectedBuild.attributes.processingState ?? "unknown",
                "uploadedDate": selectedBuild.attributes.uploadedDate ?? "",
            ]
        }
        return result
    }

    @MainActor
    func tabStateScreenshots(_ asc: ASCManager) -> [String: Any] {
        let selectedLocale = asc.selectedScreenshotsLocale ?? asc.localizations.first?.attributes.locale ?? ""
        let screenshotSets = asc.screenshotSetsForLocale(selectedLocale)
        let screenshots = asc.screenshotsForLocale(selectedLocale)
        let displayTypes = asc.orderedKnownScreenshotDisplayTypes(for: selectedLocale)
        let sets = screenshotSets.map { set -> [String: Any] in
            var value: [String: Any] = ["id": set.id, "displayType": set.attributes.screenshotDisplayType]
            if let shots = screenshots[set.id] {
                value["screenshotCount"] = shots.count
                value["screenshots"] = shots.map {
                    ["id": $0.id, "fileName": $0.attributes.fileName ?? ""]
                }
            }
            return value
        }
        let tracks = displayTypes.map { displayType -> [String: Any] in
            let currentTrack = asc.trackSlotsForDisplayType(displayType, locale: selectedLocale)
            let savedTrack = asc.savedTrackStateForDisplayType(displayType, locale: selectedLocale)
            let slots = currentTrack.enumerated().map { index, slot -> [String: Any] in
                let savedSlot = savedTrack[index]
                return [
                    "index": index,
                    "slotIndex": index + 1,
                    "id": slot?.id as Any,
                    "source": slot == nil ? "empty" : (slot?.isFromASC == true ? "asc" : "local"),
                    "fileName": slot?.ascScreenshot?.attributes.fileName
                        ?? slot?.localPath.map { ($0 as NSString).lastPathComponent } as Any,
                    "localPath": slot?.localPath as Any,
                    "isFromASC": slot?.isFromASC as Any,
                    "isSynced": slot != nil && slot?.id == savedSlot?.id,
                    "hasError": slot?.ascScreenshot?.hasError ?? false,
                    "errorDescription": slot?.ascScreenshot?.errorDescription as Any,
                ]
            }
            return [
                "displayType": displayType,
                "filledSlotCount": currentTrack.compactMap { $0 }.count,
                "hasUnsavedChanges": asc.hasUnsavedChanges(displayType: displayType, locale: selectedLocale),
                "slots": slots,
            ]
        }
        var result: [String: Any] = [
            "selectedLocale": selectedLocale,
            "availableLocales": asc.localizations.map(\.attributes.locale),
            "screenshotSets": sets,
            "displayTypes": displayTypes,
            "tracks": tracks,
            "localeCount": asc.localizations.count,
            "canCreateUpdate": asc.canCreateUpdate,
        ]
        if let selectedVersion = Self.versionStatePayload(asc.selectedVersion) {
            result["selectedVersion"] = selectedVersion
        }
        return result
    }

    @MainActor
    func tabStateReviews(_ asc: ASCManager) -> [String: Any] {
        let reviews = asc.customerReviews.prefix(20).map { review -> [String: Any] in
            [
                "id": review.id,
                "title": review.attributes.title ?? "",
                "body": review.attributes.body ?? "",
                "rating": review.attributes.rating,
                "reviewerNickname": review.attributes.reviewerNickname ?? ""
            ]
        }
        return ["reviews": reviews, "totalReviews": asc.customerReviews.count]
    }

    @MainActor
    func tabStateBuilds(_ asc: ASCManager) -> [String: Any] {
        Self.testFlightBuildListPayload(asc.builds)
    }

    @MainActor
    func tabStateGroups(_ asc: ASCManager) -> [String: Any] {
        ["betaGroups": asc.betaGroups.map(Self.testFlightGroupPayload),
         "totalGroups": asc.betaGroups.count, "truncated": false]
    }

    @MainActor
    func tabStateBetaInfo(_ asc: ASCManager) -> [String: Any] {
        let localizations = asc.betaLocalizations.map { localization -> [String: Any] in
            [
                "id": localization.id,
                "locale": localization.attributes.locale,
                "description": localization.attributes.description ?? "",
                "feedbackEmail": localization.attributes.feedbackEmail ?? "",
                "marketingUrl": localization.attributes.marketingUrl ?? "",
                "privacyPolicyUrl": localization.attributes.privacyPolicyUrl ?? ""
            ]
        }
        return ["betaLocalizations": localizations]
    }

    @MainActor
    func tabStateFeedback(_ asc: ASCManager) -> [String: Any] {
        var items: [[String: Any]] = []
        for (buildId, feedbackItems) in asc.betaFeedback {
            for item in feedbackItems {
                items.append([
                    "buildId": buildId,
                    "id": item.id,
                    "comment": item.attributes.comment ?? "",
                    "timestamp": item.attributes.timestamp ?? ""
                ])
            }
        }
        return ["feedback": items, "selectedBuildId": asc.selectedBuildId ?? ""]
    }
}
