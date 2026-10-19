import Foundation

// MARK: - Review Manager
// Extension containing review-related functionality for ASCManager

extension ASCManager {
    // MARK: - Age Rating

    func updateAgeRating(_ attributes: [String: Any]) async {
        guard let service else { return }
        guard let id = ageRatingDeclaration?.id else { return }
        let revision = projectRevision
        let startedAt = Date()
        writeError = nil
        do {
            let target = try await validateWrite(fields: ["ageRating"], using: service)
            try await service.patchAgeRating(id: id, attributes: attributes)
            try checkWriteTarget(target)
            if let infoId = target.appInfoID {
                let updated = await fetchAgeRatingLogged(
                    service: service,
                    appInfoId: infoId,
                    context: "age_rating_update"
                )
                try checkWriteTarget(target)
                ageRatingDeclaration = updated
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
