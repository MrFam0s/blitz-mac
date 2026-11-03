import Foundation

protocol ASCTestFlightService {
    func fetchBuilds(appId: String) async throws -> [ASCBuild]
    func fetchBetaGroups(appId: String) async throws -> [ASCBetaGroup]
    func fetchBetaLocalizations(appId: String) async throws -> [ASCBetaLocalization]
    func fetchBetaFeedback(appId: String, buildId: String) async throws -> [ASCBetaFeedback]
    func fetchTestFlightBuildDetail(appId: String, buildId: String) async throws -> ASCTestFlightBuildDetail
    func fetchTestFlightGroupDetail(appId: String, groupId: String) async throws -> ASCTestFlightGroupDetail
}
extension ASCTestFlightService {
    func fetchTestFlightBuildDetail(appId: String, buildId: String) async throws -> ASCTestFlightBuildDetail {
        throw ASCError.notFound("Build distribution details are unavailable.")
    }
    func fetchTestFlightGroupDetail(appId: String, groupId: String) async throws -> ASCTestFlightGroupDetail {
        throw ASCError.notFound("Group details are unavailable.")
    }
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
            testFlightBuildDetailCache.retain(ids: Set(value.map(\.id)))
            if !builds.contains(where: { $0.id == selectedTestFlightBuildId }) {
                selectedTestFlightBuildId = builds.first?.id
            }
        case .groups:
            let value = try await service.fetchBetaGroups(appId: appId)
            guard projectRevision == revision, !Task.isCancelled else { throw CancellationError() }
            betaGroups = value
            testFlightGroupDetailCache.retain(ids: Set(value.map(\.id)))
            if !betaGroups.contains(where: { $0.id == selectedTestFlightGroupId }) {
                selectedTestFlightGroupId = betaGroups.first?.id
            }
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

    var testFlightBuildDetails: [String: ASCTestFlightBuildDetail] { testFlightBuildDetailCache.values }
    var testFlightGroupDetails: [String: ASCTestFlightGroupDetail] { testFlightGroupDetailCache.values }
    var loadingTestFlightBuildIds: Set<String> { testFlightBuildDetailCache.loading }
    var loadingTestFlightGroupIds: Set<String> { testFlightGroupDetailCache.loading }
    var testFlightBuildErrors: [String: String] { testFlightBuildDetailCache.errors }
    var testFlightGroupErrors: [String: String] { testFlightGroupDetailCache.errors }

    func resetTestFlightDetailState() {
        feedbackErrorBuildId = nil
        selectedTestFlightBuildId = nil
        selectedTestFlightGroupId = nil
        testFlightBuildDetailCache.reset()
        testFlightGroupDetailCache.reset()
    }

    @discardableResult
    func refreshTestFlightBuildDetail(buildId: String, force: Bool = true, using override: (any ASCTestFlightService)? = nil) async -> Bool {
        guard let service = override ?? service, let appId = app?.id else { return false }
        let isCurrent = testFlightDetailScopeCheck(appId: appId)
        return await testFlightBuildDetailCache.refresh(id: buildId, force: force, isCurrent: isCurrent) {
            let detail = try await service.fetchTestFlightBuildDetail(appId: appId, buildId: buildId)
            guard detail.build.id == buildId, detail.build.appId == appId else {
                throw ASCError.notFound("The returned build does not belong to this app.")
            }
            return detail
        }
    }

    @discardableResult
    func refreshTestFlightGroupDetail(groupId: String, force: Bool = true, using override: (any ASCTestFlightService)? = nil) async -> Bool {
        guard let service = override ?? service, let appId = app?.id else { return false }
        let isCurrent = testFlightDetailScopeCheck(appId: appId)
        return await testFlightGroupDetailCache.refresh(id: groupId, force: force, isCurrent: isCurrent) {
            let detail = try await service.fetchTestFlightGroupDetail(appId: appId, groupId: groupId)
            guard detail.group.id == groupId, detail.group.appId == appId,
                  detail.builds.allSatisfy({ $0.appId == appId }) else {
                throw ASCError.notFound("The returned group does not match the selected group.")
            }
            return detail
        }
    }

    private func testFlightDetailScopeCheck(appId: String) -> @MainActor () -> Bool {
        let revision = projectRevision
        let account = DashboardSummaryStore.accountKey(for: credentials)
        let credentialRevision = credentialActivationRevision
        return { [weak self] in
            guard let self else { return false }
            return self.projectRevision == revision && self.app?.id == appId
                && DashboardSummaryStore.accountKey(for: self.credentials) == account
                && self.credentialActivationRevision == credentialRevision
        }
    }

    @discardableResult
    func refreshBetaFeedback(buildId: String, force: Bool = true, using override: (any ASCTestFlightService)? = nil) async -> Bool {
        guard let service = override ?? service, let appId = app?.id, !buildId.isEmpty else { return false }
        if let task = feedbackLoadTasks[buildId] { return await task.value }
        if (selectedBuildId == nil || selectedBuildId == buildId), feedbackErrorBuildId != buildId {
            tabError.removeValue(forKey: .feedback)
            feedbackErrorBuildId = nil
        }
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
                if selectedBuildId == nil || selectedBuildId == buildId {
                    tabError.removeValue(forKey: .feedback)
                    feedbackErrorBuildId = nil
                }
                // Keep only a small number of recently viewed builds in memory.
                for key in feedbackLoadedAt.sorted(by: { $0.value > $1.value }).dropFirst(12).map(\.key) {
                    feedbackLoadedAt.removeValue(forKey: key)
                    betaFeedback.removeValue(forKey: key)
                }
                return true
            } catch {
                guard projectRevision == revision, !Task.isCancelled else { return false }
                if selectedBuildId == nil || selectedBuildId == buildId {
                    tabError[.feedback] = error.localizedDescription
                    feedbackErrorBuildId = buildId
                }
                return false
            }
        }
        feedbackLoadTasks[buildId] = task
        return await task.value
    }
}
