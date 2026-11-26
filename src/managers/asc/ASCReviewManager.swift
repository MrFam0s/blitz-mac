import Foundation

// MARK: - Review Manager
// Extension containing review-related functionality for ASCManager

extension ASCManager {
    // MARK: - Age Rating

    func updateAgeRating(_ attributes: [String: Any]) async {
        let revision = projectRevision
        let startedAt = Date()
        writeError = nil
        do {
            guard let service else { throw ASCError.notFound(L10n.tr("ASC ist nicht verbunden.")) }
            guard let id = ageRatingDeclaration?.id else {
                throw ASCError.notFound(L10n.tr("Die Altersfreigabe ist noch nicht geladen."))
            }
            let target = try await validateWrite(fields: ["ageRating"], using: service)
            guard let infoID = target.appInfoID else {
                throw ASCError.notFound(L10n.tr("App-Informationen sind noch nicht geladen."))
            }
            let current = try await service.fetchAgeRating(appInfoId: infoID)
            try checkWriteTarget(target)
            guard current.id == id else { throw ASCError.notFound(L10n.tr("App-Informationen haben sich geändert.")) }
            try await service.patchAgeRating(id: id, attributes: attributes)
            try checkWriteTarget(target)
            let updated = try await service.fetchAgeRating(appInfoId: infoID)
            try checkWriteTarget(target)
            guard updated.id == id else { throw ASCError.notFound(L10n.tr("App-Informationen haben sich geändert.")) }
            ageRatingDeclaration = updated
            guard updated.attributes.confirms(answers: attributes) else {
                throw ASCError.notFound(L10n.tr("Apple hat die geänderten Antworten zur Altersfreigabe noch nicht bestätigt."))
            }
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "age_rating.update",
                success: true,
                startedAt: startedAt
            )
        } catch {
            guard revision == projectRevision else { return }
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "age_rating.update",
                success: false,
                startedAt: startedAt
            )
        }
    }

    // MARK: - Review Contact Updates

    func updateReviewContact(_ attributes: [String: Any]) async {
        guard let service else { return }
        guard let versionId = selectedVersion?.id else { return }
        let revision = projectRevision
        let startedAt = Date()
        writeError = nil
        do {
            let target = try await validateWrite(fields: ["reviewContact"], using: service)
            let updated = try await service.createOrPatchReviewDetail(versionId: versionId, attributes: attributes)
            try checkWriteTarget(target)
            reviewDetail = updated
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "review.contact.update",
                success: true,
                startedAt: startedAt
            )
        } catch {
            guard revision == projectRevision else { return }
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "review.contact.update",
                success: false,
                startedAt: startedAt
            )
        }
    }
}
