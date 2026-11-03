import Foundation

protocol ASCVersionCreationService {
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion]
    func fetchLocalizations(versionId: String) async throws -> [ASCVersionLocalization]
    func fetchReviewDetail(versionId: String) async throws -> ASCReviewDetail
    func createAppStoreVersion(appId: String, versionString: String, platform: String, copyright: String?, releaseType: String?) async throws -> ASCAppStoreVersion
    func createVersionLocalization(versionId: String, locale: String, fields: [String: String]) async throws -> ASCVersionLocalization
    func createOrPatchReviewDetail(versionId: String, attributes: [String: Any]) async throws -> ASCReviewDetail
    func attachBuild(versionId: String, buildId: String) async throws
    func fetchBuild(id: String) async throws -> ASCBuild
    func patchLocalization(id: String, fields: [String: String]) async throws
}
// Test doubles without copy conflicts or optional build attachment stay minimal.
extension ASCVersionCreationService {
    func fetchBuild(id: String) async throws -> ASCBuild { throw ASCError.notFound("Build identity could not be checked.") }
    func patchLocalization(id: String, fields: [String: String]) async throws { throw ASCError.notFound("Existing localization could not be updated.") }
}
protocol ASCVersionBuildService {
    func fetchBuildAttachedToVersion(versionId: String) async throws -> ASCBuild?
}
protocol ASCReleaseSubmissionService: ASCVersionBuildService {
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion]
    func fetchBuild(id: String) async throws -> ASCBuild
    func attachBuild(versionId: String, buildId: String) async throws
    func submitForReview(appId: String, versionId: String) async throws
}
extension AppStoreConnectService: ASCReleaseSubmissionService {}
extension AppStoreConnectService: ASCVersionCreationService {}

// MARK: - Release Manager
// Extension containing release-related functionality for ASCManager

extension ASCManager {
    private static let versionScopedTabs: Set<AppTab> = [
        .app,
        .appInformation,
        .screenshots,
        .review,
    ]

    var releaseVersions: [ASCAppStoreVersion] {
        // No local project and multiple store platforms: require an explicit
        // platform rather than mixing unrelated version histories.
        guard releasePlatform != nil || loadedProjectId == nil else { return [] }
        return ASCReleaseStatus.versions(appStoreVersions, for: releasePlatform)
    }

    func selectReleasePlatform(_ platform: ProjectPlatform?) {
        guard configuredReleasePlatform != platform else { return }
        releasePlatform = platform
        prepareForVersionSelection(nil, force: true)
        syncSelectedVersion()
    }

    func releaseOperationTarget() -> ASCReleaseOperationTarget? {
        guard let app else { return nil }
        return ASCReleaseOperationTarget(revision: projectRevision, projectId: loadedProjectId,
            appId: app.id, bundleId: app.bundleId, accountKey: DashboardSummaryStore.accountKey(for: credentials), credentialRevision: credentialActivationRevision,
            versionId: selectedVersion?.id, platform: releasePlatform)
    }

    // MARK: - Version Selection

    var liveVersion: ASCAppStoreVersion? {
        ASCReleaseStatus.currentLiveVersion(for: releaseVersions)
    }

    var currentUpdateVersion: ASCAppStoreVersion? {
        ASCReleaseStatus.currentUpdateVersion(for: releaseVersions)
    }

    var editableVersion: ASCAppStoreVersion? {
        ASCReleaseStatus.currentEditableVersion(for: releaseVersions)
    }

    var selectedVersion: ASCAppStoreVersion? {
        if let selectedVersionId,
           let match = releaseVersions.first(where: { $0.id == selectedVersionId }) {
            return match
        }
        return ASCReleaseStatus.defaultSelectedVersion(for: releaseVersions)
    }

    var selectedVersionIsEditable: Bool {
        ASCReleaseStatus.isEditable(selectedVersion?.attributes.appStoreState)
    }

    var canCreateVersion: Bool {
        app?.id != nil && releasePlatform != nil
    }

    var canStartReleaseAutomation: Bool {
        guard app != nil else { return false }
        if let current = currentUpdateVersion { return ASCReleaseStatus.isEditable(current.attributes.appStoreState) }
        return releaseVersions.contains { ASCReleaseStatus.publishedStates.contains(ASCReleaseStatus.normalize($0.attributes.appStoreState)) }
    }

    var canCreateUpdate: Bool {
        currentUpdateVersion == nil && releaseVersions.contains { ASCReleaseStatus.publishedStates.contains(ASCReleaseStatus.normalize($0.attributes.appStoreState)) }
    }

    /// ASC only allows a new version to be created when there is no existing
    /// in-flight App Store version for the app.
    var newVersionCreationBlocker: ASCAppStoreVersion? {
        currentUpdateVersion
    }

    /// The current non-live version ID, if one exists.
    var pendingVersionId: String? {
        currentUpdateVersion?.id
    }

    private var submittableVersionId: String? {
        if let selectedVersion,
           ASCReleaseStatus.isEditable(selectedVersion.attributes.appStoreState) {
            return selectedVersion.id
        }
        return nil
    }

    func version(matching identifier: String?) -> ASCAppStoreVersion? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }
        return releaseVersions.first(where: {
            $0.id == identifier || $0.attributes.versionString == identifier
        })
    }

    func rejectionCardVersionForSelectedVersion(from versions: [ASCAppStoreVersion]) -> ASCAppStoreVersion? {
        guard let selectedVersion else { return nil }

        if let feedbackVersion = feedbackDisplayVersion(from: versions),
           feedbackVersion.id == selectedVersion.id {
            return feedbackVersion
        }

        if hasRejectedSubmissionHistory(forVersionId: selectedVersion.id) {
            return selectedVersion
        }

        let normalizedState = ASCReleaseStatus.normalize(selectedVersion.attributes.appStoreState)
        guard normalizedState == "REJECTED" || normalizedState == "METADATA_REJECTED" else {
            return nil
        }

        return selectedVersion
    }

    func newVersionCreationBlockerMessage(desiredVersionString: String? = nil) -> String? {
        guard let blocker = newVersionCreationBlocker else { return nil }
        let blockerState = ASCReleaseStatus.normalize(blocker.attributes.appStoreState)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        let desiredSuffix: String
        if let desiredVersionString,
           !desiredVersionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            desiredSuffix = " before creating \(desiredVersionString)"
        } else {
            desiredSuffix = ""
        }
        return "App Store Connect already has version \(blocker.attributes.versionString) in \(blockerState). "
            + "Use that version or finish, submit, or remove it\(desiredSuffix)."
    }

    @discardableResult
    func syncSelectedVersion(preferredVersionId: String? = nil) -> String? {
        let preferred = preferredVersionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preferred,
           releaseVersions.contains(where: { $0.id == preferred }) {
            selectedVersionId = preferred
            return preferred
        }

        if let selectedVersionId,
           releaseVersions.contains(where: { $0.id == selectedVersionId }) {
            return selectedVersionId
        }

        let resolved = currentUpdateVersion?.id
            ?? editableVersion?.id
            ?? liveVersion?.id
            ?? ASCReleaseStatus.defaultSelectedVersion(for: releaseVersions)?.id
        selectedVersionId = resolved
        return resolved
    }

    func prepareForVersionSelection(_ versionId: String?, force: Bool = false) {
        let trimmedVersionId = versionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard force || trimmedVersionId != selectedVersionId else { return }

        // Version switches invalidate every cache whose contents come from a
        // version-scoped ASC resource, so the next tab refresh starts cleanly.
        let previousVersionId = selectedVersionId
        projectRevision = UUID()
        cancelIrisFeedbackLoads()
        resetTabCacheTasks()
        for task in tabLoadTasks.values { task.cancel() }
        tabLoadTasks.removeAll()
        isLoadingTab.removeAll()
        iconCheckTask?.cancel()
        iconCheckTask = nil
        overviewResolvedFields = []
        overviewFailedFields = []
        overviewCacheDate = nil
        overviewReadinessLoadingFields = Self.overviewAllFields
        selectedVersionId = trimmedVersionId
        selectedVersionBuild = nil
        localizations = []
        selectedAppInformationLocale = nil
        screenshotSetsByLocale = [:]
        screenshotsByLocale = [:]
        screenshotImageCache = [:]
        screenshotPreviewFailures = []
        selectedScreenshotsLocale = nil
        reviewDetail = nil
        writeError = nil
        versionCreationError = nil

        for tab in Self.versionScopedTabs {
            cancelBackgroundHydration(for: tab)
            loadedTabs.remove(tab)
            tabLoadedAt.removeValue(forKey: tab)
            isLoadingTab.removeValue(forKey: tab)
            tabError.removeValue(forKey: tab)
        }

        Task {
            await ASCUpdateLogger.shared.event("select_version", metadata: [
                "previousVersionId": previousVersionId ?? "nil",
                "versionId": trimmedVersionId ?? "nil",
            ])
        }
    }

    func refreshSelectedVersionBuild(using serviceOverride: (any ASCVersionBuildService)? = nil) async {
        guard let service = serviceOverride ?? service, let target = releaseOperationTarget(),
              let versionId = target.versionId else {
            selectedVersionBuild = nil
            return
        }
        do {
            let build = try await service.fetchBuildAttachedToVersion(versionId: versionId)
            guard target.matches(self), !Task.isCancelled else { return }
            selectedVersionBuild = build
        } catch {
            guard target.matches(self), !Task.isCancelled else { return }
            selectedVersionBuild = nil
        }
    }

    // MARK: - Build Attachment

    @discardableResult
    func attachBuild(buildId: String, expectedTarget: ASCReleaseOperationTarget? = nil,
                     using serviceOverride: (any ASCReleaseSubmissionService)? = nil) async -> Bool {
        guard let service = serviceOverride ?? service, let target = expectedTarget ?? releaseOperationTarget(),
              target.matches(self), let versionId = target.versionId, let platform = target.platform else { return false }
        writeError = nil
        do {
            let versions = try await service.fetchAppStoreVersions(appId: target.appId)
            try target.check(self)
            guard let version = ASCReleaseStatus.versions(versions, for: platform).first(where: { $0.id == versionId }),
                  ASCReleaseStatus.isEditable(version.attributes.appStoreState) else {
                throw ASCError.notFound("Die ausgewählte Version ist nicht mehr bearbeitbar.")
            }
            let build = try await service.fetchBuild(id: buildId)
            try target.check(self)
            guard build.matchesRelease(appId: target.appId, versionString: version.attributes.versionString, platform: platform) else {
                throw ASCError.notFound("Der Build passt nicht zu App, Plattform oder Version oder ist nicht verwendbar.")
            }
            try await service.attachBuild(versionId: versionId, buildId: buildId)
            try target.check(self)
            selectedVersionBuild = build
            return true
        } catch {
            guard target.matches(self), !Task.isCancelled else { return false }
            writeError = error.localizedDescription
            return false
        }
    }

    // MARK: - Version Creation

    @discardableResult
    func createUpdateVersion(
        versionString: String,
        platform: ProjectPlatform,
        copyFromVersionId: String? = nil,
        copyMetadata: Bool = true,
        copyReviewDetail: Bool = true,
        attachBuildId: String? = nil,
        expectedTarget: ASCReleaseOperationTarget? = nil,
        using serviceOverride: (any ASCVersionCreationService)? = nil
    ) async -> ASCAppStoreVersion? {
        guard !isCreatingVersion else { return nil }
        guard let service = serviceOverride ?? service, let target = expectedTarget ?? releaseOperationTarget(),
              target.matches(self), target.platform == nil || target.platform == platform else {
            versionCreationError = "Keine unveränderte App oder ASC-Verbindung ausgewählt."
            return nil
        }
        let operation = UUID()
        versionCreationOperation = operation
        isCreatingVersion = true
        defer {
            if versionCreationOperation == operation {
                isCreatingVersion = false
                versionCreationOperation = nil
            }
        }
        versionCreationError = nil
        let trimmedVersion = versionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ASCReleaseStatus.newVersionError(trimmedVersion, history: []) == nil else {
            versionCreationError = ASCReleaseStatus.newVersionError(trimmedVersion, history: [])
            return nil
        }
        var createdVersion: ASCAppStoreVersion?
        do {
            let freshVersions = try await service.fetchAppStoreVersions(appId: target.appId)
            try target.check(self)
            let platformVersions = ASCReleaseStatus.versions(freshVersions, for: platform)
            if let error = ASCReleaseStatus.newVersionError(trimmedVersion, history: platformVersions) {
                throw ASCError.notFound(error)
            }
            if let blocker = ASCReleaseStatus.currentUpdateVersion(for: platformVersions) {
                throw ASCError.notFound("Version \(blocker.attributes.versionString) ist bereits in Vorbereitung oder Prüfung. Bitte diesen Entwurf öffnen.")
            }
            appStoreVersions = freshVersions
            // nil means default source; the empty string is an explicit “Keine”.
            let sourceVersion: ASCAppStoreVersion?
            if let identifier = copyFromVersionId?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if identifier.isEmpty { sourceVersion = nil }
                else if let source = platformVersions.first(where: { $0.id == identifier || $0.attributes.versionString == identifier }) { sourceVersion = source }
                else { throw ASCError.notFound("Die gewählte Quellversion gehört nicht zu dieser App und Plattform.") }
            } else {
                sourceVersion = ASCReleaseStatus.currentLiveVersion(for: platformVersions)
                    ?? platformVersions.first { ASCReleaseStatus.publishedStates.contains(ASCReleaseStatus.normalize($0.attributes.appStoreState)) }
            }
            let sourceLocalizations: [ASCVersionLocalization]
            if copyMetadata, let sourceVersion {
                sourceLocalizations = try await service.fetchLocalizations(versionId: sourceVersion.id)
                try target.check(self)
            } else { sourceLocalizations = [] }
            let sourceReviewDetail: ASCReviewDetail?
            if copyReviewDetail, let sourceVersion {
                do { sourceReviewDetail = try await service.fetchReviewDetail(versionId: sourceVersion.id) }
                catch ASCError.notFound { sourceReviewDetail = nil }
                catch let ASCError.httpError(code, _) where code == 404 { sourceReviewDetail = nil }
                try target.check(self)
            } else { sourceReviewDetail = nil }

            var attachedBuild: ASCBuild?
            if let buildId = attachBuildId?.trimmingCharacters(in: .whitespacesAndNewlines), !buildId.isEmpty {
                let build = try await service.fetchBuild(id: buildId)
                try target.check(self)
                guard build.matchesRelease(appId: target.appId, versionString: trimmedVersion, platform: platform) else {
                    throw ASCError.notFound("Der Build passt nicht zu App, Plattform oder neuer Version oder ist nicht verwendbar.")
                }
                attachedBuild = build
            }
            try target.check(self)
            let created = try await service.createAppStoreVersion(appId: target.appId,
                versionString: trimmedVersion, platform: platform.ascPlatformValue,
                copyright: copyMetadata ? sourceVersion?.attributes.copyright : nil, releaseType: "MANUAL")
            createdVersion = created
            try target.check(self)
            for localization in sourceLocalizations {
                let fields = versionLocalizationFieldsToCopy(localization)
                do {
                    _ = try await service.createVersionLocalization(versionId: created.id, locale: localization.attributes.locale, fields: fields)
                } catch let error as ASCError where error.isConflict {
                    try target.check(self)
                    // Apple can create the primary localization automatically. Only
                    // resolve that exact conflict; other failures remain visible.
                    let existing = try await service.fetchLocalizations(versionId: created.id)
                    try target.check(self)
                    guard let destination = existing.first(where: { $0.attributes.locale == localization.attributes.locale }) else { throw error }
                    try await service.patchLocalization(id: destination.id, fields: fields)
                }
                try target.check(self)
            }
            if let sourceReviewDetail {
                _ = try await service.createOrPatchReviewDetail(versionId: created.id, attributes: reviewDetailAttributesToCopy(sourceReviewDetail))
                try target.check(self)
            }
            if let attachedBuild {
                try await service.attachBuild(versionId: created.id, buildId: attachedBuild.id)
                try target.check(self)
            }
            let refreshedVersions = try await service.fetchAppStoreVersions(appId: target.appId)
            try target.check(self)
            appStoreVersions = refreshedVersions
            prepareForVersionSelection(created.id)
            syncSelectedVersion(preferredVersionId: created.id)
            showVersionDraftSheet = false
            await refreshTabData(.app)
            return created
        } catch {
            guard target.matches(self), !Task.isCancelled else { return nil }
            if let createdVersion {
                if !appStoreVersions.contains(where: { $0.id == createdVersion.id }) { appStoreVersions.insert(createdVersion, at: 0) }
                // Preserve the created draft and report partial completion explicitly;
                // a retry must repair it rather than create another version.
                versionCreationError = "Entwurf \(createdVersion.attributes.versionString) wurde angelegt, aber nicht vollständig vorbereitet: \(error.localizedDescription)"
            } else { versionCreationError = error.localizedDescription }
            return nil
        }
    }

    // MARK: - Submission

    @discardableResult
    func submitForReview(attachBuildId: String? = nil, expectedTarget: ASCReleaseOperationTarget? = nil,
                         using serviceOverride: (any ASCReleaseSubmissionService)? = nil) async -> Bool {
        guard !isSubmitting, let service = serviceOverride ?? service,
              let target = expectedTarget ?? releaseOperationTarget(), target.matches(self),
              let versionId = target.versionId, let platform = target.platform else { return false }
        let operation = UUID()
        releaseSubmissionOperation = operation
        isSubmitting = true
        submissionError = nil
        defer {
            if releaseSubmissionOperation == operation {
                isSubmitting = false
                releaseSubmissionOperation = nil
            }
        }
        do {
            let versions = try await service.fetchAppStoreVersions(appId: target.appId)
            try target.check(self)
            guard let version = ASCReleaseStatus.versions(versions, for: platform).first(where: { $0.id == versionId }),
                  ASCReleaseStatus.isEditable(version.attributes.appStoreState) else {
                throw ASCError.notFound("Die ausgewählte Version ist nicht mehr zur Einreichung bearbeitbar.")
            }
            let build: ASCBuild?
            if let buildId = attachBuildId, !buildId.isEmpty { build = try await service.fetchBuild(id: buildId) }
            else { build = try await service.fetchBuildAttachedToVersion(versionId: versionId) }
            try target.check(self)
            guard let build, build.matchesRelease(appId: target.appId, versionString: version.attributes.versionString, platform: platform) else {
                throw ASCError.notFound("Kein verwendbarer Build für diese App, Plattform und Version ausgewählt.")
            }
            if serviceOverride == nil {
                await syncOverviewSubmissionReadiness(forceRefresh: true)
                try target.check(self)
                guard submissionReadiness.isComplete(selectingBuild: build) else {
                    throw ASCError.notFound("Erforderliche Angaben fehlen oder konnten nicht frisch geprüft werden.")
                }
            }
            if attachBuildId != nil {
                try await service.attachBuild(versionId: versionId, buildId: build.id)
                try target.check(self)
            }
            selectedVersionBuild = build
            try await service.submitForReview(appId: target.appId, versionId: versionId)
            try target.check(self)
            await refreshTabData(.app)
            return true
        } catch {
            guard target.matches(self), !Task.isCancelled else { return false }
            submissionError = error.localizedDescription
            return false
        }
    }

    // MARK: - Localization Flushing

    func flushPendingLocalizations() async {
        guard let service else { return }
        let appInfoLocFieldNames: Set<String> = ["name", "title", "subtitle", "privacyPolicyUrl"]
        for (tab, fields) in pendingFormValues {
            if tab == "appInformation" {
                let locale = activeAppInformationLocale()
                var versionLocFields: [String: String] = [:]
                var infoLocFields: [String: String] = [:]
                for (field, value) in fields {
                    if appInfoLocFieldNames.contains(field) {
                        let apiField = (field == "title") ? "name" : field
                        infoLocFields[apiField] = value
                    } else {
                        versionLocFields[field] = value
                    }
                }
                if !versionLocFields.isEmpty, let locId = appInformationLocalization(locale: locale)?.id {
                    try? await service.patchLocalization(id: locId, fields: versionLocFields)
                }
                if !infoLocFields.isEmpty, let infoLocId = appInfoLocalizationForLocale(locale)?.id {
                    try? await service.patchAppInfoLocalization(id: infoLocId, fields: infoLocFields)
                }
            }
        }
        pendingFormValues = [:]
    }
}

private extension ASCManager {
    func versionLocalizationFieldsToCopy(_ localization: ASCVersionLocalization) -> [String: String] {
        var fields: [String: String] = [:]
        if let title = localization.attributes.title, !title.isEmpty {
            fields["title"] = title
        }
        if let subtitle = localization.attributes.subtitle, !subtitle.isEmpty {
            fields["subtitle"] = subtitle
        }
        if let description = localization.attributes.description, !description.isEmpty {
            fields["description"] = description
        }
        if let keywords = localization.attributes.keywords, !keywords.isEmpty {
            fields["keywords"] = keywords
        }
        if let promotionalText = localization.attributes.promotionalText, !promotionalText.isEmpty {
            fields["promotionalText"] = promotionalText
        }
        if let marketingUrl = localization.attributes.marketingUrl, !marketingUrl.isEmpty {
            fields["marketingUrl"] = marketingUrl
        }
        if let supportUrl = localization.attributes.supportUrl, !supportUrl.isEmpty {
            fields["supportUrl"] = supportUrl
        }
        return fields
    }

    func reviewDetailAttributesToCopy(_ detail: ASCReviewDetail) -> [String: Any] {
        var attributes: [String: Any] = [:]
        let source = detail.attributes
        if let contactFirstName = source.contactFirstName, !contactFirstName.isEmpty {
            attributes["contactFirstName"] = contactFirstName
        }
        if let contactLastName = source.contactLastName, !contactLastName.isEmpty {
            attributes["contactLastName"] = contactLastName
        }
        if let contactPhone = source.contactPhone, !contactPhone.isEmpty {
            attributes["contactPhone"] = contactPhone
        }
        if let contactEmail = source.contactEmail, !contactEmail.isEmpty {
            attributes["contactEmail"] = contactEmail
        }
        if let demoAccountRequired = source.demoAccountRequired {
            attributes["demoAccountRequired"] = demoAccountRequired
        }
        if let demoAccountName = source.demoAccountName, !demoAccountName.isEmpty {
            attributes["demoAccountName"] = demoAccountName
        }
        if let demoAccountPassword = source.demoAccountPassword, !demoAccountPassword.isEmpty {
            attributes["demoAccountPassword"] = demoAccountPassword
        }
        if let notes = source.notes, !notes.isEmpty {
            attributes["notes"] = notes
        }
        return attributes
    }
}
