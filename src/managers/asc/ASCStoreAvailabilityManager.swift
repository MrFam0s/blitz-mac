import Foundation

protocol ASCStoreAvailabilityFetching {
    func fetchStoreAvailability(appId: String) async throws -> ASCStoreAvailability
}
extension AppStoreConnectService: ASCStoreAvailabilityFetching {}

struct ASCStoreAvailabilityContext: Equatable {
    let revision: UUID
    let projectID: String?
    let appID: String
    let account: String?
    let credentialRevision: Int
}

extension ASCManager {
    static let storeAvailabilityFreshness: TimeInterval = 120

    var currentStoreAvailabilityContext: ASCStoreAvailabilityContext? {
        guard let app else { return nil }
        return .init(revision: projectRevision, projectID: loadedProjectId,
                     appID: app.id, account: DashboardSummaryStore.accountKey(for: credentials),
                     credentialRevision: credentialActivationRevision)
    }

    /// Display evidence only. Version selection, copying and submission rules must
    /// continue to use version metadata independently of storefront availability.
    var confirmedStoreAvailability: ASCStoreAvailability? {
        guard storeAvailabilityContext == currentStoreAvailabilityContext,
              storeAvailabilityContext != nil,
              !isStoreAvailabilityLoading, !storeAvailabilityFailed,
              let date = storeAvailabilityUpdatedAt,
              Date().timeIntervalSince(date) >= -60,
              Date().timeIntervalSince(date) < Self.storeAvailabilityFreshness else { return nil }
        return storeAvailability
    }

    var distributionReadyVersion: ASCAppStoreVersion? {
        var seenPlatforms = Set<String>()
        for version in ASCReleaseStatus.sortedVersionsByRecency(releaseVersions) {
            let state = ASCReleaseStatus.normalize(version.attributes.effectiveState)
            guard ASCReleaseStatus.publishedStates.contains(state) else { continue }
            let platform = ASCReleaseStatus.normalize(version.attributes.platform)
            guard seenPlatforms.insert(platform).inserted else { continue }
            if ASCReleaseStatus.isLive(state) { return version }
        }
        return nil
    }

    var storeLiveVersion: ASCAppStoreVersion? {
        confirmedStoreAvailability == .available ? distributionReadyVersion : nil
    }

    func resetStoreAvailability() {
        storeAvailabilityTask?.cancel()
        storeAvailabilityTask = nil
        storeAvailabilityRequestID = nil
        storeAvailabilityContext = nil
        storeAvailability = nil
        storeAvailabilityUpdatedAt = nil
        isStoreAvailabilityLoading = false
        storeAvailabilityFailed = false
    }

    func refreshStoreAvailabilityIfNeeded() async {
        guard credentials != nil, let service, !restoringCache else { return }
        await refreshStoreAvailability(using: service, force: false)
    }

    /// One account/project-bound read is shared by all tabs. Nothing is restored
    /// from listing caches: a cached approved version is never proof of availability.
    func refreshStoreAvailability(using service: any ASCStoreAvailabilityFetching, force: Bool = false) async {
        guard let context = currentStoreAvailabilityContext else { return }
        if storeAvailabilityContext != context { resetStoreAvailability() }
        if let task = storeAvailabilityTask { await task.value; return }
        if !force, confirmedStoreAvailability != nil { return }

        let requestID = UUID()
        storeAvailabilityContext = context
        storeAvailabilityRequestID = requestID
        isStoreAvailabilityLoading = true
        storeAvailability = nil
        storeAvailabilityUpdatedAt = nil
        storeAvailabilityFailed = false
        let task = Task { [self] in
            defer {
                if storeAvailabilityRequestID == requestID {
                    isStoreAvailabilityLoading = false
                    storeAvailabilityTask = nil
                    storeAvailabilityRequestID = nil
                }
            }
            do {
                let value = try await service.fetchStoreAvailability(appId: context.appID)
                guard currentStoreAvailabilityContext == context,
                      storeAvailabilityRequestID == requestID, !Task.isCancelled else { return }
                storeAvailability = value
                storeAvailabilityUpdatedAt = Date()
                storeAvailabilityFailed = false
            } catch {
                guard currentStoreAvailabilityContext == context,
                      storeAvailabilityRequestID == requestID else { return }
                // Old evidence cannot keep a green badge after an unsuccessful refresh.
                storeAvailability = nil
                storeAvailabilityUpdatedAt = nil
                storeAvailabilityFailed = !Task.isCancelled && !(error is CancellationError)
            }
        }
        storeAvailabilityTask = task
        // The manager/context owns this shared request. Canceling one waiting
        // view must not cancel the read still needed by another tab.
        await task.value
    }
}
