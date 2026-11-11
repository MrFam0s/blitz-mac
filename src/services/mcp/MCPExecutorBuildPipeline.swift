import Foundation

/// Serializes pipeline ownership; finishing an older request cannot clear a newer operation.
struct BuildPipelineOperationState {
    private(set) var operationID: UUID?
    mutating func begin() -> UUID? {
        guard operationID == nil else { return nil }
        let id = UUID()
        operationID = id
        return id
    }
    mutating func finish(_ id: UUID) -> Bool {
        guard operationID == id else { return false }
        operationID = nil
        return true
    }
}

extension MCPExecutor {
    // MARK: - Build Pipeline Tools

    struct UploadedArtifactMetadata {
        let shortVersion: String?
        let buildNumber: String?
        let hasEncryptionDeclaration: Bool
    }

    private struct BuildUploadObservation {
        let upload: ASCBuildUpload?
        let build: ASCBuild?
        let timedOut: Bool
        let error: String?
    }

    static func artifactMetadata(fromPlistXML plistXML: String) -> UploadedArtifactMetadata? {
        guard let data = plistXML.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        func cleanedString(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return UploadedArtifactMetadata(
            shortVersion: cleanedString(plist["CFBundleShortVersionString"]),
            buildNumber: cleanedString(plist["CFBundleVersion"]),
            hasEncryptionDeclaration: plist.keys.contains("ITSAppUsesNonExemptEncryption")
        )
    }

    static func buildUploadProcessingHint(codes: [String]) -> String? {
        let normalized = Set(codes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })

        let appIconCodes: Set<String> = ["90022", "90023", "90713"]
        if !normalized.isDisjoint(with: appIconCodes) {
            return "Likely cause: the app icon payload is missing or invalid. Verify AppIcon.appiconset includes a valid 1024x1024 App Store icon plus the required platform icon sizes, then rebuild."
        }

        return nil
    }

    private static func ascPlatformString(for platform: ProjectPlatform) -> String {
        platform == .macOS ? "MAC_OS" : "IOS"
    }

    private static func parseASCDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: trimmed) {
            return parsed
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    private static func buildUploadAssociationDate(_ upload: ASCBuildUpload) -> Date? {
        parseASCDate(upload.attributes.createdDate) ?? parseASCDate(upload.attributes.uploadedDate)
    }

    private static func buildUploadStateEntries(
        _ details: [ASCBuildUpload.Attributes.AssetState.StateDetail]?
    ) -> [[String: Any]] {
        (details ?? []).map { detail in
            var entry: [String: Any] = [:]
            if let code = detail.code, !code.isEmpty {
                entry["code"] = code
            }
            if let message = detail.message, !message.isEmpty {
                entry["message"] = message
            }
            return entry
        }.filter { !$0.isEmpty }
    }

    private static func buildUploadStatusMessage(upload: ASCBuildUpload?, build: ASCBuild?) -> String {
        if let build {
            let buildState = build.attributes.processingState ?? "UNKNOWN"
            return "Build \(build.attributes.version) is \(buildState) on App Store Connect."
        }

        if let upload {
            let uploadState = upload.attributes.state?.state ?? "UNKNOWN"
            return "Upload \(upload.id) is \(uploadState) on App Store Connect."
        }

        return "Upload committed, but the App Store Connect upload record is not visible yet."
    }

    private static func isTerminalBuildState(_ state: String?) -> Bool {
        guard let state else {
            return false
        }
        let normalized = state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            return false
        }
        return ["VALID", "INVALID", "FAILED"].contains(normalized)
    }

    private func findRecentBuildUpload(
        service: AppStoreConnectService,
        appId: String,
        metadata: BuildArtifactMetadata,
        platform: ProjectPlatform,
        uploadStartedAt: Date,
        uploadCompletedAt: Date
    ) async throws -> ASCBuildUpload? {
        let uploads = try await service.fetchBuildUploads(
            appId: appId,
            shortVersion: metadata.shortVersion,
            buildNumber: metadata.buildNumber,
            platform: Self.ascPlatformString(for: platform),
            limit: 50
        )

        let lowerBound = uploadStartedAt.addingTimeInterval(-5)
        let upperBound = uploadCompletedAt.addingTimeInterval(60)
        for upload in uploads {
            guard let associationAt = Self.buildUploadAssociationDate(upload) else { continue }
            guard associationAt >= lowerBound, associationAt <= upperBound else { continue }
            return upload
        }

        return nil
    }

    private func observeBuildUpload(
        service: AppStoreConnectService,
        appId: String,
        preferredUploadId: String?,
        metadata: BuildArtifactMetadata,
        platform: ProjectPlatform,
        uploadStartedAt: Date,
        uploadCompletedAt: Date,
        waitBudget: TimeInterval,
        pollInterval: TimeInterval = 3,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> BuildUploadObservation {
        let deadline = Date().addingTimeInterval(max(0, waitBudget))
        var resolvedUploadId = preferredUploadId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedUploadId?.isEmpty == true {
            resolvedUploadId = nil
        }
        var lastUpload: ASCBuildUpload?
        var lastBuild: ASCBuild?
        var lastProgressMessage: String?
        var waited = false
        var observationError: String?

        while true {
            do {
                if resolvedUploadId == nil,
                   let matchedUpload = try await findRecentBuildUpload(
                       service: service,
                       appId: appId,
                       metadata: metadata,
                       platform: platform,
                       uploadStartedAt: uploadStartedAt,
                       uploadCompletedAt: uploadCompletedAt
                   ) {
                    resolvedUploadId = matchedUpload.id
                    lastUpload = matchedUpload
                }

                if let resolvedUploadId {
                    let upload = try await service.fetchBuildUpload(id: resolvedUploadId)
                    guard upload.attributes.cfBundleShortVersionString == metadata.shortVersion,
                          upload.attributes.cfBundleVersion == metadata.buildNumber,
                          upload.attributes.platform == Self.ascPlatformString(for: platform) else {
                        throw BuildArtifactMetadata.ValidationError(message: "The App Store upload record does not match the uploaded version, build number and platform.")
                    }
                    lastUpload = upload
                    if let buildId = upload.buildId, !buildId.isEmpty {
                        lastBuild = try await service.fetchBuild(id: buildId)
                    }

                    let progressMessage = Self.buildUploadStatusMessage(upload: upload, build: lastBuild)
                    if progressMessage != lastProgressMessage {
                        onProgress(progressMessage)
                        lastProgressMessage = progressMessage
                    }

                    if upload.attributes.state?.state?.uppercased() == "FAILED"
                        || Self.isTerminalBuildState(lastBuild?.attributes.processingState) {
                        return BuildUploadObservation(upload: lastUpload, build: lastBuild, timedOut: false, error: nil)
                    }
                }
                observationError = nil
            } catch {
                observationError = "Upload was committed, but status verification failed: \(error.localizedDescription)"
                onProgress(observationError!)
                break
            }

            if Task.isCancelled {
                observationError = "Upload was committed; status observation was cancelled. Inspect this upload before retrying."
                break
            }
            if Date() >= deadline {
                break
            }

            waited = true
            try? await Task.sleep(for: .seconds(pollInterval))
        }

        return BuildUploadObservation(upload: lastUpload, build: lastBuild, timedOut: waited, error: observationError)
    }

    func executeSetupSigning(_ args: [String: Any]) async throws -> [String: Any] {
        let (optCtx, err) = await requireBuildContext()
        guard let ctx = optCtx else { return err! }
        let project = ctx.project
        let bundleId = ctx.bundleId
        let service = ctx.service
        let teamId = args["teamId"] as? String ?? (ctx.teamId.isEmpty ? nil : ctx.teamId)

        await MainActor.run {
            appState.ascManager.buildPipelinePhase = .signingSetup
            appState.ascManager.buildPipelineMessage = "Setting up signing…"
        }

        let pipeline = BuildPipelineService()
        let appStateRef = appState
        do {
            let projectPlatform = await MainActor.run { project.platform }
            let result = try await withThrowingTimeout(seconds: 300) {
                try await pipeline.setupSigning(
                    projectPath: project.path,
                    bundleId: bundleId,
                    accountKey: ctx.accountKey,
                    teamId: teamId,
                    ascService: service,
                    platform: projectPlatform,
                    scheme: project.metadata.buildSettings?.scheme,
                    configuration: project.metadata.buildSettings?.configuration,
                    onProgress: { msg in
                        Task { @MainActor in
                            guard Self.releaseApprovalTargetMatches(appStateRef) else { return }
                            appStateRef.ascManager.buildPipelineMessage = msg
                        }
                    }
                )
            }

            try await MCPMutationScope.checkBeforeWrite()
            if !result.teamId.isEmpty {
                await MainActor.run {
                    let storage = ProjectStorage()
                    guard var metadata = storage.readMetadata(projectId: project.id) else { return }
                    metadata.teamId = result.teamId
                    try? storage.writeMetadata(projectId: project.id, metadata: metadata)
                }
            }

            await MainActor.run {
                guard Self.releaseApprovalTargetMatches(appState) else { return }
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }

            var resultDict: [String: Any] = [
                "success": true,
                "bundleIdResourceId": result.bundleIdResourceId,
                "certificateId": result.certificateId,
                "profileUUID": result.profileUUID,
                "teamId": result.teamId,
                "log": result.log
            ]
            if let installerCertId = result.installerCertificateId {
                resultDict["installerCertificateId"] = installerCertId
            }
            return mcpJSON(resultDict)
        } catch {
            await MainActor.run {
                guard Self.releaseApprovalTargetMatches(appState) else { return }
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }
            return mcpText("Error in signing setup: \(error.localizedDescription)")
        }
    }

    @MainActor private static var pipelineOperations: [ObjectIdentifier: BuildPipelineOperationState] = [:]

    private struct PipelineTarget {
        let operationID: UUID
        let project: Project
        let bundleID: String
        let teamID: String
        let appID: String
        let platform: ProjectPlatform
        let releaseTargetID: String
        let version: ASCAppStoreVersion?
        let selectedVersionID: String?
        let revision: UUID
        let accountKey: String
        let credentialRevision: Int
        let credentials: ASCCredentials
        let service: AppStoreConnectService
    }

    private func capturePipelineTarget(needsTeamID: Bool = false) async throws -> PipelineTarget {
        try await MainActor.run {
            let asc = appState.ascManager
            guard Self.releaseApprovalTargetMatches(appState),
                  let project = appState.activeProject, asc.loadedProjectId == project.id,
                  let app = asc.app, let credentials = asc.credentials,
                  let accountKey = DashboardSummaryStore.accountKey(for: credentials), let service = asc.service else {
                throw BuildArtifactMetadata.ValidationError(message: "The active app/account is not fully loaded or changed during approval. Reopen the intended project and retry.")
            }
            guard asc.buildPipelinePhase == .idle else {
                throw BuildArtifactMetadata.ValidationError(message: "Another build pipeline operation is already running for this project.")
            }
            let metadata = ProjectStorage().readMetadata(projectId: project.id) ?? project.metadata
            guard let configured = metadata.selectedReleaseTarget,
                  configured.id == project.selectedReleaseTarget?.id,
                  let bundleID = configured.bundleIdentifier, bundleID == app.bundleId else {
                throw BuildArtifactMetadata.ValidationError(message: "The project's Bundle ID does not match the loaded App Store app.")
            }
            let registeredProject = Project(id: project.id, metadata: metadata, path: project.path)
            _ = try RegisteredReleaseTarget.resolve(project: registeredProject, releaseTargetID: configured.id,
                appID: app.id, bundleID: bundleID, platform: configured.platform.ascPlatformValue, accountKey: accountKey)
            let teamID = metadata.teamId ?? ""
            guard !needsTeamID || !teamID.isEmpty else {
                throw BuildArtifactMetadata.ValidationError(message: "No team ID is set. Run app_store_setup_signing first.")
            }
            let version: ASCAppStoreVersion?
            if let selected = asc.selectedVersion, ASCReleaseStatus.isEditable(selected.attributes.appStoreState) {
                version = selected
            } else {
                // A TestFlight-only upload must not silently select another draft.
                version = nil
            }
            let key = ObjectIdentifier(appState)
            var operation = Self.pipelineOperations[key] ?? BuildPipelineOperationState()
            guard let operationID = operation.begin() else {
                throw BuildArtifactMetadata.ValidationError(message: "A build/upload operation is already running. Wait for its result before starting another.")
            }
            Self.pipelineOperations[key] = operation
            asc.buildPipelinePhase = needsTeamID ? .archiving : .uploading
            asc.buildPipelineMessage = "Validating build inputs…"
            return PipelineTarget(operationID: operationID, project: registeredProject, bundleID: bundleID, teamID: teamID,
                                  appID: app.id, platform: configured.platform, releaseTargetID: configured.id, version: version,
                                  selectedVersionID: asc.selectedVersion?.id, revision: asc.projectRevision,
                                  accountKey: accountKey, credentialRevision: asc.credentialActivationRevision,
                                  credentials: credentials, service: service)
        }
    }

    @MainActor private static func pipelineTargetMatches(_ target: PipelineTarget, appState: AppState) -> Bool {
        let asc = appState.ascManager
        return Self.pipelineOperations[ObjectIdentifier(appState)]?.operationID == target.operationID
            && appState.activeProject?.id == target.project.id
            && appState.activeProject?.selectedReleaseTarget?.id == target.releaseTargetID
            && (asc.loadedReleaseTargetId == target.releaseTargetID
                || (asc.loadedReleaseTargetId == nil && target.releaseTargetID == "legacy" && target.project.releaseTargets.count == 1))
            && asc.loadedProjectId == target.project.id && asc.app?.id == target.appID
            && asc.app?.bundleId == target.bundleID && asc.projectRevision == target.revision
            && asc.selectedVersion?.id == target.selectedVersionID
            && DashboardSummaryStore.accountKey(for: asc.credentials) == target.accountKey
            && asc.credentialActivationRevision == target.credentialRevision
    }

    private func requireCurrentPipelineTarget(_ target: PipelineTarget) async throws {
        guard !Task.isCancelled, await MainActor.run(body: { Self.pipelineTargetMatches(target, appState: appState) }) else {
            throw BuildArtifactMetadata.ValidationError(message: "The app, account or selected version changed during this operation. No further changes were made; reopen the original app to inspect the result.")
        }
    }

    private func finishPipelineUI(_ target: PipelineTarget) async {
        await MainActor.run {
            let key = ObjectIdentifier(appState)
            guard var operation = Self.pipelineOperations[key], operation.finish(target.operationID) else { return }
            Self.pipelineOperations.removeValue(forKey: key)
            // The owned progress display must clear even if only the selected version changed.
            appState.ascManager.buildPipelinePhase = .idle
            appState.ascManager.buildPipelineMessage = ""
        }
    }

    /// App Store build trains are scoped by marketing version on iOS, but macOS build
    /// numbers must keep increasing across marketing versions. Never suggest Int(max)+1.
    static func validateBuildNumber(_ metadata: BuildArtifactMetadata, appID: String, existing: [ASCBuild]) throws {
        var highest: String?
        for build in existing {
            guard build.appId == appID, let train = build.preReleaseVersion else {
                throw BuildArtifactMetadata.ValidationError(message: "Cannot verify the existing build identities. Refresh App Store Connect before uploading.")
            }
            guard train.attributes.platform == ascPlatformString(for: metadata.platform),
                  metadata.platform == .macOS || train.attributes.version == metadata.shortVersion else { continue }
            let number = build.attributes.version
            guard let order = BuildArtifactMetadata.compareNumbers(metadata.buildNumber, number) else {
                throw BuildArtifactMetadata.ValidationError(message: "Existing build number '\(number)' could not be compared safely. Inspect this build train before uploading.")
            }
            if order != .orderedDescending {
                if highest == nil || BuildArtifactMetadata.compareNumbers(number, highest!) == .orderedDescending {
                    highest = number
                }
            }
        }
        if let highest {
            throw BuildArtifactMetadata.ValidationError(message: "Build \(metadata.buildNumber) is already used or is not newer than \(highest) for this app/platform/version. Choose a greater CFBundleVersion, including its dotted components, and rebuild.")
        }
    }

    func executeBuildIPA(_ args: [String: Any]) async throws -> [String: Any] {
        let target: PipelineTarget
        do { target = try await capturePipelineTarget(needsTeamID: true) }
        catch { return mcpText("Error building artifact: \(error.localizedDescription)") }
        let scheme = (args["scheme"] as? String) ?? target.project.metadata.buildSettings?.scheme
        let configuration = (args["configuration"] as? String) ?? target.project.metadata.buildSettings?.configuration
        await MainActor.run {
            guard Self.pipelineTargetMatches(target, appState: appState) else { return }
            appState.ascManager.buildPipelinePhase = .archiving
            appState.ascManager.buildPipelineMessage = "Starting build…"
        }
        let appStateRef = appState
        do {
            try await requireCurrentPipelineTarget(target)
            let result = try await BuildPipelineService().buildIPA(
                projectPath: target.project.path, bundleId: target.bundleID, accountKey: target.accountKey, teamId: target.teamID,
                scheme: scheme, configuration: configuration, platform: target.platform,
                destination: target.project.selectedReleaseTarget?.buildSettings?.destination,
                onProgress: { message in
                    Task { @MainActor in
                        guard Self.pipelineTargetMatches(target, appState: appStateRef) else { return }
                        if message.contains("ARCHIVE SUCCEEDED") || message.contains("-exportArchive") {
                            appStateRef.ascManager.buildPipelinePhase = .exporting
                        }
                        appStateRef.ascManager.buildPipelineMessage = String(message.prefix(120))
                    }
                }
            )
            await finishPipelineUI(target)
            return mcpJSON(["success": true, "ipaPath": result.ipaPath, "archivePath": result.archivePath,
                            "appId": target.appID, "bundleId": target.bundleID, "log": result.log])
        } catch {
            await finishPipelineUI(target)
            return mcpText("Error building artifact: \(error.localizedDescription)")
        }
    }

    func executeUploadToTestFlight(_ args: [String: Any]) async throws -> [String: Any] {
        let target: PipelineTarget
        do { target = try await capturePipelineTarget() }
        catch { return mcpText("Error uploading to TestFlight: \(error.localizedDescription)") }
        guard let path = args["ipaPath"] as? String, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await finishPipelineUI(target)
            return mcpText("Error: provide the explicit ipaPath returned by app_store_build (IPA or PKG). Exports from other projects are never selected automatically.")
        }
        let artifactURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let skipPolling = args["skipPolling"] as? Bool ?? false
        let commandStartedAt = Date()
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("BlitzUpload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        var uploadCommitted = false
        var uploadStarted = false
        var committedUploadID: String?
        let appStateRef = appState
        do {
            // Upload the same snapshot that was inspected, even if a later build replaces the source file.
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let snapshot = staging.appendingPathComponent(artifactURL.lastPathComponent)
            try FileManager.default.copyItem(at: artifactURL, to: snapshot)
            let metadata = try await BuildArtifactMetadata.read(artifactURL: snapshot, platform: target.platform)
            try metadata.validate(bundleID: target.bundleID, platform: target.platform,
                                  version: target.version?.attributes.versionString)
            guard metadata.usesNonExemptEncryption != nil else {
                throw BuildArtifactMetadata.ValidationError(message: "ITSAppUsesNonExemptEncryption is missing. Declare the app's actual encryption use as YES or NO in its Info.plist and rebuild; Blitz will not invent this declaration.")
            }
            if let version = target.version {
                guard version.attributes.platform == Self.ascPlatformString(for: target.platform),
                      ASCReleaseStatus.isEditable(version.attributes.appStoreState) else {
                    throw BuildArtifactMetadata.ValidationError(message: "The captured App Store version is not an editable version of this platform.")
                }
            }
            let freshApp = try await target.service.fetchApp(id: target.appID)
            guard freshApp.bundleId == metadata.bundleID else {
                throw BuildArtifactMetadata.ValidationError(message: "The server's App Store app does not match the artifact's Bundle ID.")
            }
            let existingBuilds = try await target.service.fetchBuilds(appId: target.appID)
            try Self.validateBuildNumber(metadata, appID: target.appID, existing: existingBuilds)
            try await requireCurrentPipelineTarget(target)
            await MainActor.run {
                guard Self.pipelineTargetMatches(target, appState: appState) else { return }
                appState.ascManager.buildPipelinePhase = .uploading
                appState.ascManager.buildPipelineMessage = "Uploading artifact…"
            }
            let uploadStartedAt = Date()
            uploadStarted = true
            let result = try await BuildPipelineService().uploadToTestFlight(
                ipaPath: snapshot.path, keyId: target.credentials.keyId, issuerId: target.credentials.issuerId,
                privateKeyPEM: target.credentials.privateKey, appId: target.appID, ascService: target.service,
                skipPolling: skipPolling, platform: target.platform, metadata: metadata,
                onProgress: { message in
                    Task { @MainActor in
                        guard Self.pipelineTargetMatches(target, appState: appStateRef) else { return }
                        appStateRef.ascManager.buildPipelineMessage = String(message.prefix(120))
                    }
                }
            )
            uploadCommitted = result.uploadCommitted
            committedUploadID = result.uploadId
            let uploadCompletedAt = Date()
            var allLog = result.log
            let remainingBudget = max(0, 95 - Date().timeIntervalSince(commandStartedAt))
            let observation = await observeBuildUpload(
                service: target.service, appId: target.appID, preferredUploadId: result.uploadId,
                metadata: metadata, platform: target.platform, uploadStartedAt: uploadStartedAt,
                uploadCompletedAt: uploadCompletedAt, waitBudget: min(skipPolling ? 6 : 25, remainingBudget),
                onProgress: { message in
                    Task { @MainActor in
                        guard Self.pipelineTargetMatches(target, appState: appStateRef) else { return }
                        appStateRef.ascManager.buildPipelinePhase = .processing
                        appStateRef.ascManager.buildPipelineMessage = String(message.prefix(120))
                    }
                }
            )
            let observedUpload = observation.upload
            let observedBuild = observation.build
            let uploadState = observedUpload?.attributes.state?.state ?? "UPLOAD_COMMITTED"
            let buildState = observedBuild?.attributes.processingState ?? "UNKNOWN"
            let failed = uploadState.uppercased() == "FAILED" || ["INVALID", "FAILED"].contains(buildState.uppercased())
            let validated = buildState.uppercased() == "VALID"
            var followUpError = observation.error
            var attachedVersionID: String?
            if !failed, validated, let build = observedBuild {
                do {
                    guard build.matchesRelease(appId: target.appID, versionString: metadata.shortVersion, platform: target.platform),
                          build.attributes.version == metadata.buildNumber else {
                        throw BuildArtifactMetadata.ValidationError(message: "The processed build identity does not match the uploaded app, version, build number and platform. It was not attached.")
                    }
                    try await requireCurrentPipelineTarget(target)
                    if let version = target.version {
                        let versions = try await target.service.fetchAppStoreVersions(appId: target.appID)
                        guard let freshVersion = versions.first(where: { $0.id == version.id }),
                              freshVersion.attributes.versionString == metadata.shortVersion,
                              freshVersion.attributes.platform == Self.ascPlatformString(for: target.platform),
                              ASCReleaseStatus.isEditable(freshVersion.attributes.appStoreState) else {
                            throw BuildArtifactMetadata.ValidationError(message: "The captured App Store version changed or is no longer editable. The upload succeeded but was not attached.")
                        }
                        try await requireCurrentPipelineTarget(target)
                        try await target.service.patchBuildEncryption(buildId: build.id, usesNonExemptEncryption: metadata.usesNonExemptEncryption!)
                        try await requireCurrentPipelineTarget(target)
                        try await target.service.attachBuild(versionId: version.id, buildId: build.id)
                        attachedVersionID = version.id
                        allLog.append("Build \(metadata.shortVersion) (\(build.attributes.version)) attached to the captured App Store version \(version.id).")
                        await MainActor.run {
                            guard Self.pipelineTargetMatches(target, appState: appStateRef), appStateRef.ascManager.selectedVersion?.id == version.id else { return }
                            appStateRef.ascManager.selectedVersionBuild = build
                        }
                    }
                } catch { followUpError = error.localizedDescription }
            }
            await finishPipelineUI(target)
            if let followUpError { allLog.append(followUpError) }
            let codes = (observedUpload?.attributes.state?.errors ?? []).compactMap(\.code)
            var response: [String: Any] = [
                "success": !failed && followUpError == nil, "uploadCommitted": result.uploadCommitted,
                "appId": target.appID, "bundleId": metadata.bundleID,
                "versionString": metadata.shortVersion, "buildNumber": metadata.buildNumber,
                "buildVersion": metadata.buildNumber, "processingState": buildState, "uploadState": uploadState,
                "followUpRequired": !failed && (!validated || followUpError != nil),
                "message": Self.buildUploadStatusMessage(upload: observedUpload, build: observedBuild), "log": allLog
            ]
            if let id = observedUpload?.id ?? result.uploadId { response["uploadId"] = id }
            if let id = result.fileId { response["fileId"] = id }
            if let id = observedBuild?.id { response["buildId"] = id }
            if let attachedVersionID { response["attachedVersionId"] = attachedVersionID }
            if let followUpError { response["followUpError"] = followUpError }
            let errors = Self.buildUploadStateEntries(observedUpload?.attributes.state?.errors)
            let warnings = Self.buildUploadStateEntries(observedUpload?.attributes.state?.warnings)
            if !errors.isEmpty { response["uploadErrors"] = errors }
            if !warnings.isEmpty { response["uploadWarnings"] = warnings }
            if let hint = Self.buildUploadProcessingHint(codes: codes) { response["diagnosticHint"] = hint }
            return mcpJSON(response)
        } catch {
            await finishPipelineUI(target)
            if uploadStarted {
                var response: [String: Any] = ["success": false, "uploadCommitted": uploadCommitted, "followUpRequired": true,
                                                "uploadOutcome": uploadCommitted ? "COMMITTED" : "UNKNOWN",
                                                "appId": target.appID, "followUpError": error.localizedDescription,
                                                "message": "Upload was attempted. Check this app's upload/build records before retrying; a transport error does not prove that Apple received nothing."]
                if let committedUploadID { response["uploadId"] = committedUploadID }
                return mcpJSON(response)
            }
            return mcpText("Error uploading to TestFlight: \(error.localizedDescription)")
        }
    }
}
