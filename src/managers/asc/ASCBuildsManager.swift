import Foundation

protocol ASCTestFlightService {
    func fetchBuilds(appId: String) async throws -> [ASCBuild]
    func fetchBetaGroups(appId: String) async throws -> [ASCBetaGroup]
    func fetchBetaLocalizations(appId: String) async throws -> [ASCBetaLocalization]
    func fetchBetaFeedback(appId: String, buildId: String) async throws -> [ASCBetaFeedback]
}
extension AppStoreConnectService: ASCTestFlightService {}

extension ASCManager {
    func loadTestFlightTab(_ tab: AppTab, using service: any ASCTestFlightService) async throws {
        guard let appId = app?.id else { return }
        let revision = projectRevision
        switch tab {
        case .builds:
            let value = try await service.fetchBuilds(appId: appId)
            guard projectRevision == revision, !Task.isCancelled else { throw CancellationError() }
            builds = value
        case .groups:
            let value = try await service.fetchBetaGroups(appId: appId)
            guard projectRevision == revision, !Task.isCancelled else { throw CancellationError() }
            betaGroups = value
        case .betaInfo:
            let value = try await service.fetchBetaLocalizations(appId: appId)
            guard projectRevision == revision, !Task.isCancelled else { throw CancellationError() }
            betaLocalizations = value
        case .feedback:
            await ensureTabData(.builds)
            guard projectRevision == revision, !Task.isCancelled else { throw CancellationError() }
            if let error = tabError[.builds], builds.isEmpty { throw ASCError.notFound(error) }
            if selectedBuildId == nil || !builds.contains(where: { $0.id == selectedBuildId }) {
                selectedBuildId = builds.first?.id
            }
            if let buildId = selectedBuildId {
                guard await refreshBetaFeedback(buildId: buildId, using: service) else {
                    throw ASCError.notFound(tabError[.feedback] ?? "Could not refresh tester feedback")
                }
            }
        default: break
        }
    }

    @discardableResult
    func refreshBetaFeedback(buildId: String, force: Bool = true, using override: (any ASCTestFlightService)? = nil) async -> Bool {
        guard let service = override ?? service, let appId = app?.id, !buildId.isEmpty else { return false }
        if let task = feedbackLoadTasks[buildId] { return await task.value }
        if !force, betaFeedback[buildId] != nil, let date = feedbackLoadedAt[buildId],
           Date().timeIntervalSince(date) < 120 { return true }
        let revision = projectRevision
        loadingFeedbackBuildIds.insert(buildId)
        let task = Task { [self] in
            defer {
                if projectRevision == revision {
                    loadingFeedbackBuildIds.remove(buildId)
                    feedbackLoadTasks.removeValue(forKey: buildId)
                }
            }
            do {
                let items = try await service.fetchBetaFeedback(appId: appId, buildId: buildId)
                guard projectRevision == revision, !Task.isCancelled else { return false }
                betaFeedback[buildId] = items
                feedbackLoadedAt[buildId] = Date()
                if selectedBuildId == nil || selectedBuildId == buildId { tabError.removeValue(forKey: .feedback) }
                // Keep only a small number of recently viewed builds in memory.
                for key in feedbackLoadedAt.sorted(by: { $0.value > $1.value }).dropFirst(12).map(\.key) {
                    feedbackLoadedAt.removeValue(forKey: key)
                    betaFeedback.removeValue(forKey: key)
                }
                return true
            } catch {
                guard projectRevision == revision, !Task.isCancelled else { return false }
                if selectedBuildId == nil || selectedBuildId == buildId { tabError[.feedback] = error.localizedDescription }
                return false
            }
        }
        feedbackLoadTasks[buildId] = task
        return await task.value
    }
}
