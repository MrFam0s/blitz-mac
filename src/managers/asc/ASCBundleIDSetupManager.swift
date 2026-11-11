import Foundation

@MainActor
protocol ASCAppCreationService {
    func fetchBundleId(identifier: String) async throws -> ASCBundleId?
    func registerBundleId(identifier: String, name: String, platform: String) async throws -> ASCBundleId
    func enableCapability(bundleIdResourceId: String, capabilityType: String) async throws
    func fetchApp(bundleId: String, exactName: String?) async throws -> ASCApp
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion]
}

extension AppStoreConnectService: ASCAppCreationService {}

extension ASCManager {
    struct PendingBundleIDSetupContext {
        let operationId: UUID
        let projectId: String
        let accountKey: String
        let expectedIssuerId: String
        let expectedKeyId: String
        let revision: UUID
        var identity: AppCreationIdentity
        let tab: AppTab
        var registrationComplete = false
        var releaseTargetId: String? = nil
        var bundleId: String { identity.bundleId }
    }

    struct AppCreationFormRequest {
        let id = UUID()
        let context: PendingBundleIDSetupContext
        let message: String?
    }

    /// A recovery request is local UI state, never permission to create another app.
    var activeAppCreationFormRequest: AppCreationFormRequest? {
        guard let request = appCreationFormRequest, app == nil,
              loadedProjectId == request.context.projectId,
              projectRevision == request.context.revision,
              DashboardSummaryStore.accountKey(for: credentials) == request.context.accountKey else { return nil }
        return request
    }

    @discardableResult
    func reopenAppCreationForm(projectId: String, operationId: String, message: String? = nil) throws -> AppCreationFormRequest {
        guard let context = pendingBundleIDSetup, context.registrationComplete, app == nil else {
            throw BundleIDSetupConfirmationError.missingBundleId
        }
        try validateBundleIDSetupContext(context)
        guard context.projectId == projectId, context.operationId.uuidString == operationId else {
            throw BundleIDSetupConfirmationError.staleOperation
        }
        let notice = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = AppCreationFormRequest(context: context,
            message: notice.flatMap { $0.isEmpty ? nil : String($0.prefix(2000)) })
        // Invalidate the old confirmation before exposing the form for correction.
        pendingBundleIDSetup = nil
        appCreationFormRequest = request
        return request
    }

    struct BundleIDRegistrationResult {
        let context: PendingBundleIDSetupContext
        let capabilitiesEnabled: Int
        let canonicalIdentifierNotice: String?
    }

    enum BundleIDSetupConfirmationError: LocalizedError {
        case ascServiceNotConfigured
        case missingBundleId
        case staleOperation
        case identityMismatch
        case projectUnavailable

        var errorDescription: String? {
            switch self {
            case .ascServiceNotConfigured: return "ASC service not configured"
            case .missingBundleId: return "No confirmed app-creation operation is open. Return to bundle-ID setup first."
            case .staleOperation: return "The project, account or app-creation operation changed. Return to the original project and restart setup."
            case .identityMismatch: return "The supplied app identity does not match the confirmed creation operation. No app was assigned."
            case .projectUnavailable: return "The original project is no longer available. No project metadata was updated."
            }
        }
    }

    @discardableResult
    func beginPendingBundleIDSetup(identity: AppCreationIdentity, tab: AppTab, requireRegisteredProject: Bool = true) throws -> PendingBundleIDSetupContext {
        try identity.validate()
        guard let projectId = loadedProjectId, let credentials,
              let accountKey = DashboardSummaryStore.accountKey(for: credentials) else {
            throw BundleIDSetupConfirmationError.projectUnavailable
        }
        var context = PendingBundleIDSetupContext(operationId: UUID(), projectId: projectId, accountKey: accountKey,
            expectedIssuerId: credentials.issuerId, expectedKeyId: credentials.keyId, revision: projectRevision, identity: identity, tab: tab)
        if let metadata = ProjectStorage().readMetadata(projectId: projectId) {
            context.releaseTargetId = try identity.validateProjectTarget(metadata, targetId: nil, registrationComplete: false)
        } else if requireRegisteredProject {
            throw BundleIDSetupConfirmationError.projectUnavailable
        }
        pendingBundleIDSetup = context
        appCreationFormRequest = nil
        return context
    }

    func clearPendingBundleIDSetup() { pendingBundleIDSetup = nil }

    func validateBundleIDSetupContext(_ context: PendingBundleIDSetupContext) throws {
        guard !Task.isCancelled, loadedProjectId == context.projectId,
              projectRevision == context.revision,
              DashboardSummaryStore.accountKey(for: credentials) == context.accountKey,
              pendingBundleIDSetup?.operationId == context.operationId else {
            throw BundleIDSetupConfirmationError.staleOperation
        }
        if let targetID = context.releaseTargetId {
            guard let metadata = ProjectStorage().readMetadata(projectId: context.projectId) else {
                throw BundleIDSetupConfirmationError.staleOperation
            }
            _ = try context.identity.validateProjectTarget(metadata, targetId: targetID,
                registrationComplete: context.registrationComplete)
        }
    }

    func registerBundleIDForCreation(
        identity: AppCreationIdentity, tab: AppTab, capabilities: [String],
        using overrideService: (any ASCAppCreationService)? = nil,
        persist: ((String, String) throws -> Void)? = nil
    ) async throws -> BundleIDRegistrationResult {
        guard let creationService = overrideService ?? service else { throw BundleIDSetupConfirmationError.ascServiceNotConfigured }
        var context = try beginPendingBundleIDSetup(identity: identity, tab: tab, requireRegisteredProject: overrideService == nil)
        var completed = false
        defer {
            if !completed, pendingBundleIDSetup?.operationId == context.operationId { pendingBundleIDSetup = nil }
        }
        let existing = try await creationService.fetchBundleId(identifier: identity.bundleId)
        try validateBundleIDSetupContext(context)
        let registered: ASCBundleId
        if let existing { registered = existing }
        else {
            registered = try await creationService.registerBundleId(identifier: identity.bundleId, name: identity.appName,
                platform: identity.platform == .macOS ? "MAC_OS" : "IOS")
            try validateBundleIDSetupContext(context)
        }
        let canonical = registered.attributes.identifier
        guard AppCreationIdentity.validBundleID(canonical), canonical.caseInsensitiveCompare(identity.bundleId) == .orderedSame else {
            throw BundleIDSetupConfirmationError.identityMismatch
        }
        // Apple IDs are case-insensitive. Keep the actual registered spelling visible
        // instead of claiming that a case-only variation created a new identifier.
        context.identity.bundleId = canonical
        pendingBundleIDSetup = context
        var enabled = 0
        for capability in capabilities {
            try validateBundleIDSetupContext(context)
            // A conflict can describe a real configuration problem, not just an
            // already-enabled capability. Never report an unverified 409 as success.
            try await creationService.enableCapability(bundleIdResourceId: registered.id, capabilityType: capability)
            try validateBundleIDSetupContext(context)
            enabled += 1
        }
        try validateBundleIDSetupContext(context)
        if let persist { try persist(context.projectId, canonical) }
        else {
            let storage = ProjectStorage()
            guard var metadata = storage.readMetadata(projectId: context.projectId) else { throw BundleIDSetupConfirmationError.projectUnavailable }
            metadata.bundleIdentifier = canonical
            try storage.writeMetadata(projectId: context.projectId, metadata: metadata)
        }
        context.registrationComplete = true
        pendingBundleIDSetup = context
        completed = true
        return BundleIDRegistrationResult(context: context, capabilitiesEnabled: enabled,
            canonicalIdentifierNotice: canonical == identity.bundleId ? nil : "Apple already registered this identifier as ‘\(canonical)’. This exact spelling will be used below.")
    }

    func confirmBundleIDSetupAppCreated(
        bundleId: String? = nil, expectedName: String? = nil, expectedSKU: String? = nil,
        expectedPlatform: String? = nil, expectedLocale: String? = nil,
        projectId: String? = nil, operationId: String? = nil, releaseTargetId: String? = nil,
        using overrideService: (any ASCAppCreationService)? = nil, refreshData: Bool = true
    ) async throws -> ASCApp {
        guard let context = pendingBundleIDSetup, context.registrationComplete else { throw BundleIDSetupConfirmationError.missingBundleId }
        try validateBundleIDSetupContext(context)
        if let releaseTargetId, releaseTargetId != context.releaseTargetId {
            throw BundleIDSetupConfirmationError.identityMismatch
        }
        if context.releaseTargetId != nil,
           (ProjectStorage().readMetadata(projectId: context.projectId)?.resolvedReleaseTargets.count ?? 0) > 1,
           releaseTargetId != context.releaseTargetId {
            throw BundleIDSetupConfirmationError.identityMismatch
        }
        for (provided, expected) in [(bundleId, context.identity.bundleId), (expectedName, context.identity.appName),
            (expectedSKU, context.identity.sku), (expectedPlatform, context.identity.platform.rawValue),
            (expectedLocale, context.identity.primaryLocale), (projectId, context.projectId),
            (operationId, context.operationId.uuidString)] {
            if let provided, provided != expected { throw BundleIDSetupConfirmationError.identityMismatch }
        }
        guard let creationService = overrideService ?? service else { throw BundleIDSetupConfirmationError.ascServiceNotConfigured }
        let fetched = try await creationService.fetchApp(bundleId: context.identity.bundleId, exactName: nil)
        try validateBundleIDSetupContext(context)
        let versions = try await creationService.fetchAppStoreVersions(appId: fetched.id)
        try validateBundleIDSetupContext(context)
        try context.identity.verify(app: fetched, versions: versions)
        if let targetID = context.releaseTargetId {
            let storage = ProjectStorage()
            guard var metadata = storage.readMetadata(projectId: context.projectId),
                  var target = metadata.releaseTarget(id: targetID),
                  target.bundleIdentifier == fetched.bundleId else { throw BundleIDSetupConfirmationError.staleOperation }
            target.storeBinding = ProjectStoreBinding(appId: fetched.id, accountKey: context.accountKey,
                sku: fetched.attributes.sku, bundleIdentifier: fetched.bundleId)
            try metadata.upsertReleaseTarget(target)
            try storage.writeMetadata(projectId: context.projectId, metadata: metadata)
        }
        self.app = fetched
        credentialsError = nil
        pendingBundleIDSetup = nil
        resetTabState()
        let confirmedRevision = projectRevision
        if context.releaseTargetId != nil {
            await appState?.projectManager.loadProjects()
            guard loadedProjectId == context.projectId, projectRevision == confirmedRevision,
                  DashboardSummaryStore.accountKey(for: credentials) == context.accountKey,
                  ProjectStorage().readMetadata(projectId: context.projectId)?.selectedReleaseTarget?.id == context.releaseTargetId else {
                throw BundleIDSetupConfirmationError.staleOperation
            }
        }
        if refreshData { await fetchTabData(context.tab) }
        guard loadedProjectId == context.projectId, projectRevision == confirmedRevision,
              DashboardSummaryStore.accountKey(for: credentials) == context.accountKey else {
            throw BundleIDSetupConfirmationError.staleOperation
        }
        return fetched
    }
}
