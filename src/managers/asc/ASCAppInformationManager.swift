import Foundation

protocol ASCAppInformationService {
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion]
    func fetchAppInfo(appId: String) async throws -> ASCAppInfo
    func fetchLocalizations(versionId: String) async throws -> [ASCVersionLocalization]
    func fetchAppInfoLocalizations(appInfoId: String) async throws -> [ASCAppInfoLocalization]
}
extension AppStoreConnectService: ASCAppInformationService {}

// MARK: - App Information Manager
// Extension containing merged app-information functionality for ASCManager

extension ASCManager {
    // MARK: - Locale Selection

    /// Primary app-information locale from ASC app settings, falling back to
    /// the first loaded version localization.
    func primaryAppInformationLocale() -> String? {
        if let primaryLocale = app?.primaryLocale,
           localizations.contains(where: { $0.attributes.locale == primaryLocale }) {
            return primaryLocale
        }
        return localizations.first?.attributes.locale
    }

    /// Primary version-localization record used for overview/readiness, independent of the active editor locale.
    func primaryVersionLocalization(in candidates: [ASCVersionLocalization]? = nil) -> ASCVersionLocalization? {
        let candidates = candidates ?? localizations
        guard let primaryLocale = app?.primaryLocale else { return candidates.first }
        return candidates.first(where: { $0.attributes.locale == primaryLocale }) ?? candidates.first
    }

    /// Primary app-info-localization record used for overview/readiness, independent of the active editor locale.
    func primaryAppInfoLocalization(in candidates: [ASCAppInfoLocalization]? = nil) -> ASCAppInfoLocalization? {
        let primaryLocale = app?.primaryLocale

        if let primaryLocale,
           let match = candidates?.first(where: { $0.attributes.locale == primaryLocale }) ?? appInfoLocalizationsByLocale[primaryLocale] {
            return match
        }

        return candidates?.first ?? appInfoLocalization
    }

    /// Active app-information locale for the UI/editor, preferring the user's
    /// selected locale when it is still valid.
    func activeAppInformationLocale() -> String? {
        selectedAppInformationLocale.flatMap { locale in
            localizations.contains(where: { $0.attributes.locale == locale }) ? locale : nil
        } ?? primaryAppInformationLocale()
    }

    func appInformationLocalization(locale: String? = nil) -> ASCVersionLocalization? {
        if let locale {
            return localizations.first(where: { $0.attributes.locale == locale })
        }
        return primaryVersionLocalization()
    }

    func appInfoLocalizationForLocale(_ locale: String? = nil) -> ASCAppInfoLocalization? {
        if let resolvedLocale = locale ?? activeAppInformationLocale() {
            return appInfoLocalizationsByLocale[resolvedLocale]
        }
        return primaryAppInfoLocalization()
    }

    /// Release notes are only mandatory when the selected version is an update
    /// on top of an already-live App Store version.
    var selectedVersionRequiresWhatsNew: Bool {
        guard let selectedVersion, let liveVersion else { return false }
        guard selectedVersion.id != liveVersion.id else { return false }
        return ASCReleaseStatus.isCurrentUpdateCandidate(selectedVersion.attributes.appStoreState)
    }

    /// App Store Connect validates `What's New` per version localization, so the
    /// readiness model has to look at every localization on the selected update.
    func selectedVersionLocalizationsMissingWhatsNew(
        in candidates: [ASCVersionLocalization]? = nil
    ) -> [ASCVersionLocalization] {
        guard selectedVersionRequiresWhatsNew else { return [] }
        let candidates = candidates ?? localizations
        return candidates
            .filter { localization in
                localization.attributes.whatsNew?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ?? true
            }
            .sorted { lhs, rhs in
                lhs.attributes.locale.localizedCompare(rhs.attributes.locale) == .orderedAscending
            }
    }

    func refreshAppInformationMetadata(
        service: any ASCAppInformationService,
        appId: String,
        preferredVersionId: String? = nil,
        preferredLocale: String? = nil
    ) async throws {
        let revision = projectRevision
        async let versionsTask = service.fetchAppStoreVersions(appId: appId)
        async let appInfoTask = service.fetchAppInfo(appId: appId)

        let versions = try await versionsTask
        let fetchedAppInfo = try await appInfoTask

        guard projectRevision == revision, !Task.isCancelled else { throw CancellationError() }
        let resolvedVersionId = [preferredVersionId, selectedVersionId].compactMap { $0 }
            .first(where: { id in versions.contains { $0.id == id } })
            ?? ASCReleaseStatus.defaultSelectedVersion(for: versions)?.id
        async let infoLocalizationsTask = service.fetchAppInfoLocalizations(appInfoId: fetchedAppInfo.id)

        let versionLocalizations: [ASCVersionLocalization]
        if let resolvedVersionId {
            versionLocalizations = try await service.fetchLocalizations(versionId: resolvedVersionId)
        } else {
            versionLocalizations = []
        }

        let fetchedAppInfoLocalizations = try await infoLocalizationsTask

        guard projectRevision == revision, !Task.isCancelled else { throw CancellationError() }
        if let preferredLocale {
            selectedAppInformationLocale = preferredLocale
        }

        appStoreVersions = versions
        selectedVersionId = resolvedVersionId
        appInfo = fetchedAppInfo
        localizations = versionLocalizations
        appInfoLocalizationsByLocale = Dictionary(uniqueKeysWithValues: fetchedAppInfoLocalizations.map {
            ($0.attributes.locale, $0)
        })

        appInfoLocalization = primaryAppInfoLocalization(in: fetchedAppInfoLocalizations)
        selectedAppInformationLocale = activeAppInformationLocale()
        await persistTabCache(.appInformation)
    }

    // MARK: - App Information Updates

    private func mappedAppInfoLocalizationFields(_ fields: [String: String]) -> [String: String] {
        var mapped: [String: String] = [:]
        for (field, value) in fields {
            mapped[field == "title" ? "name" : field] = value
        }
        return mapped
    }

    func updateVersionLocalizationField(_ field: String, value: String, locale: String) async {
        await updateAppInformationFields(
            versionFields: [field: value],
            appInfoFields: [:],
            locale: locale
        )
    }

    func updateAppInformationFields(
        versionFields: [String: String],
        appInfoFields rawAppInfoFields: [String: String],
        locale: String
    ) async {
        guard let service else { return }
        let trimmedLocale = locale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLocale.isEmpty else {
            writeError = "No app information locale selected."
            return
        }

        let revision = projectRevision
        let startedAt = Date()
        writeError = nil

        do {
            let fields = Set(versionFields.keys).union(rawAppInfoFields.keys)
            let target = try await validateWrite(fields: fields, using: service)
            if !versionFields.isEmpty {
                guard let locId = appInformationLocalization(locale: trimmedLocale)?.id else {
                    throw ASCError.notFound("Version localization for locale '\(trimmedLocale)'")
                }
                try await service.patchLocalization(id: locId, fields: versionFields)
            }

            let appInfoFields = mappedAppInfoLocalizationFields(rawAppInfoFields)
            if !appInfoFields.isEmpty {
                try checkWriteTarget(target)
                guard let infoId = appInfo?.id else {
                    throw ASCError.notFound("AppInfo")
                }

                if let locId = appInfoLocalizationForLocale(trimmedLocale)?.id {
                    try await service.patchAppInfoLocalization(id: locId, fields: appInfoFields)
                } else {
                    _ = try await service.createAppInfoLocalization(
                        appInfoId: infoId,
                        locale: trimmedLocale,
                        fields: appInfoFields
                    )
                }
            }

            try checkWriteTarget(target)
            guard let appId = app?.id else { return }
            try await refreshAppInformationMetadata(
                service: service,
                appId: appId,
                preferredVersionId: selectedVersion?.id,
                preferredLocale: trimmedLocale
            )
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "app_information.update",
                success: true,
                startedAt: startedAt
            )
        } catch {
            guard revision == projectRevision else { return }
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "app_information.update",
                success: false,
                startedAt: startedAt
            )
        }
    }

    func updateAppInfoField(_ field: String, value: String) async {
        guard let service else { return }
        let startedAt = Date()
        let revision = projectRevision
        writeError = nil
        do {
            let target = try await validateWrite(fields: [field], using: service)
            if field == "copyright", let versionId = target.versionID {
                try await service.patchVersion(id: versionId, fields: [field: value])
                try checkWriteTarget(target)
                let versions = try await service.fetchAppStoreVersions(appId: target.appID)
                try checkWriteTarget(target)
                appStoreVersions = versions
                syncSelectedVersion(preferredVersionId: versionId)
            } else if field == "contentRightsDeclaration" {
                try await service.patchApp(id: target.appID, fields: [field: value])
                try checkWriteTarget(target)
                let updated = try await service.fetchApp(id: target.appID)
                try checkWriteTarget(target)
                app = updated
            } else if let infoId = target.appInfoID {
                try await service.patchAppInfo(id: infoId, fields: [field: value])
                try checkWriteTarget(target)
                let updated = try await service.fetchAppInfoRecord(id: infoId)
                try checkWriteTarget(target)
                appInfo = updated
            }
            AnalyticsService.trackBlitzManagedASCUsage(commandType: "app_information.update", success: true, startedAt: startedAt)
        } catch {
            guard revision == projectRevision else { return }
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(commandType: "app_information.update", success: false, startedAt: startedAt)
        }
    }

    func updatePrivacyPolicyUrl(_ url: String) async {
        await updateAppInfoLocalizationField("privacyPolicyUrl", value: url)
    }

    /// Update a field on app-info localizations (`name`, `subtitle`,
    /// `privacyPolicyUrl`) for the active app-information locale.
    func updateAppInfoLocalizationField(_ field: String, value: String, locale: String? = nil) async {
        let targetLocale = locale ?? activeAppInformationLocale()
        guard let targetLocale else {
            writeError = "No app info localization selected."
            return
        }

        await updateAppInformationFields(
            versionFields: [:],
            appInfoFields: [field: value],
            locale: targetLocale
        )
    }
}
