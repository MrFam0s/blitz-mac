import AppKit
import Foundation

@MainActor
@Observable
final class SimulatorStreamManager {
    private(set) var captureService = SimulatorCaptureService()
    private(set) var interaction: DeviceInteractionService?
    private(set) var usesNativePreview = false
    private(set) var nativeImage: CGImage?
    private var nativePreviewTask: Task<Void, Never>?
    private let previewVisible: @MainActor () -> Bool
    private let listDevices: @Sendable () async throws -> [SimctlClient.SimctlDevice]
    var renderer: MetalRenderer?
    var isCapturing = false
    var errorMessage: String?
    private(set) var needsScreenRecordingPermission = false
    private(set) var needsAccessibilityPermission = false
    private(set) var stoppedDeviceID: String?
    private(set) var closedWindowDeviceID: String?
    private(set) var usesDeviceHub = false
    private(set) var viewport: DeviceHubScreenGeometry.Viewport?
    private(set) var devicePointSize: CGSize?
    private(set) var geometryRevision = 0
    private(set) var isTouchReady = false
    var statusMessage: String?
    /// True when the stream was paused by a tab switch (not manually stopped)
    var isPaused = false

    private var rendererInitialized = false
    private var selectedDeviceID: String?
    private var fallbackScreens: [SimulatorScreen]?

    func isPreviewing(_ udid: String) -> Bool {
        isCapturing && selectedDeviceID?.caseInsensitiveCompare(udid) == .orderedSame
    }

    init(listDevices: @escaping @Sendable () async throws -> [SimctlClient.SimctlDevice] = { try await SimctlClient().listDevices() },
         previewVisible: @escaping @MainActor () -> Bool = {
        NSApp?.windows.contains { $0.canBecomeMain && $0.occlusionState.contains(.visible) } == true
    }) {
        self.previewVisible = previewVisible
        self.listDevices = listDevices
    }

    private func windowCapture(for session: DeviceInteractionService) -> SimulatorCaptureService {
        let capture = SimulatorCaptureService()
        capture.onTouchAvailabilityChange = { [weak self, weak session] ready in
            guard let self, let session, self.interaction === session else { return }
            self.isTouchReady = ready
            if !ready, self.devicePointSize != nil {
                self.geometryRevision += 1
                self.devicePointSize = nil
            }
        }
        capture.onGeometryChange = { [weak self, weak session] state in
            guard let self, let session, self.interaction === session else { return }
            await self.updateGeometry(state)
        }
        return capture
    }

    static func prefersNativePreview(deviceType: String?, integratedScreenCount: Int, viewer: SimulatorApplication.Kind?,
                                     screenRecordingAllowed: Bool, accessibilityAllowed: Bool) -> Bool {
        if deviceType == SimulatorPose.deviceType || integratedScreenCount > 1 { return true }
        return integratedScreenCount == 1 && (viewer == nil || !screenRecordingAllowed || (viewer == .deviceHub && !accessibilityAllowed))
    }

    static func deviceHasStopped(udid: String, in devices: [SimctlClient.SimctlDevice]?) -> Bool {
        guard let devices else { return false }
        return !devices.contains { $0.udid.caseInsensitiveCompare(udid) == .orderedSame && $0.isBooted }
    }

    /// An explicit start captures the viewer it opened. A passive visit can attach
    /// to an existing window in either viewer, subject to its current permissions.
    static func windowViewers(openIfNeeded: Bool, accessibilityAllowed: Bool,
                              openPreferred: () async throws -> SimulatorApplication.Kind) async throws -> [SimulatorApplication.Kind] {
        if openIfNeeded { return [try await openPreferred()] }
        return accessibilityAllowed ? [.deviceHub, .simulator] : [.simulator]
    }

    private func endWindowCapture(_ error: Error, deviceID: String, session: DeviceInteractionService) async {
        isTouchReady = false
        let devices = try? await listDevices()
        guard interaction === session, !Task.isCancelled else { return }
        let failure = error as? SimulatorCaptureService.CaptureError
        isCapturing = false
        statusMessage = nil
        errorMessage = nil
        needsAccessibilityPermission = false
        needsScreenRecordingPermission = false
        if Self.deviceHasStopped(udid: deviceID, in: devices) {
            stoppedDeviceID = deviceID
        } else if case .simulatorWindowClosed = failure {
            closedWindowDeviceID = deviceID
        } else if let fallbackScreens, failure?.requiresAccessibilityPermission == true || failure?.requiresScreenRecordingPermission == true {
            startNativePreview(udid: deviceID, session: session, screens: fallbackScreens)
            return
        } else {
            errorMessage = error.localizedDescription
            needsAccessibilityPermission = failure?.requiresAccessibilityPermission == true
            needsScreenRecordingPermission = failure?.requiresScreenRecordingPermission == true
        }
        await closeInteraction()
    }

    private func updateGeometry(_ state: SimulatorCaptureService.Geometry) async {
        let visible: DeviceHubScreenGeometry.Viewport?
        switch state {
        case .deviceHub(let viewport):
            usesDeviceHub = true
            visible = viewport
        case .classic:
            usesDeviceHub = false
            visible = nil
        case .failed(let error):
            if let selectedDeviceID, let interaction {
                await endWindowCapture(error, deviceID: selectedDeviceID, session: interaction)
            }
            return
        }
        guard viewport != visible || devicePointSize == nil else { return }
        geometryRevision += 1
        let revision = geometryRevision
        viewport = visible
        devicePointSize = nil
        guard let visible, let udid = selectedDeviceID, let interaction else { return }
        let native = try? await interaction.activeScreenSize(udid: udid)
        guard revision == geometryRevision, selectedDeviceID == udid else { return }
        devicePointSize = native.flatMap { visible.orientedPoints(for: $0) }
    }

    func ensureRenderer() {
        guard !rendererInitialized else { return }
        rendererInitialized = true
        do {
            renderer = try MetalRenderer()
        } catch {
            errorMessage = L10n.tr("Metal konnte nicht initialisiert werden: \(error.localizedDescription)")
        }
    }

    /// Tab navigation may attach a preview, while an explicit start may also open its viewer.
    func startStreaming(bootedDeviceId: String?, openViewerIfNeeded: Bool = true) async {
        guard !isCapturing, interaction == nil else { return }
        guard let bootedDeviceId else {
            statusMessage = nil
            return
        }
        let session = DeviceInteractionService()
        let capture = windowCapture(for: session)
        captureService = capture
        interaction = session
        selectedDeviceID = bootedDeviceId

        errorMessage = nil
        stoppedDeviceID = nil
        closedWindowDeviceID = nil
        needsScreenRecordingPermission = false
        needsAccessibilityPermission = false
        isPaused = false
        statusMessage = openViewerIfNeeded ? L10n.tr("Simulator wird geöffnet …") : nil
        let service = SimulatorService()
        do {
            let devices = try await listDevices()
            try Task.checkCancellation()
            guard interaction === session else { return }
            guard let device = devices.first(where: { $0.udid.caseInsensitiveCompare(bootedDeviceId) == .orderedSame && $0.isBooted }) else {
                stoppedDeviceID = bootedDeviceId
                statusMessage = nil
                await closeInteraction()
                return
            }
            let screens = try? await SimctlClient().integratedScreens(udid: bootedDeviceId)
            let accessibilityAllowed = AXIsProcessTrusted()
            let screenRecordingAllowed = CGPreflightScreenCaptureAccess()
            // A classic Simulator window requires no AX lookup to determine its bounds.
            let viewer = try? await service.viewer(preferred: accessibilityAllowed ? .deviceHub : .simulator)
            guard interaction === session, !Task.isCancelled else { throw CancellationError() }
            // During first boot CoreSimulator may advertise a known Duo before
            // both screen descriptors appear. Keep retrying its native displays.
            fallbackScreens = screens?.isEmpty == false ? screens : nil
            let duplicateName = devices.filter { $0.isBooted && $0.name == device.name }.count != 1
            if Self.prefersNativePreview(deviceType: device.deviceTypeIdentifier, integratedScreenCount: screens?.count ?? 0,
                                         viewer: viewer?.kind, screenRecordingAllowed: screenRecordingAllowed,
                                         accessibilityAllowed: accessibilityAllowed) || (duplicateName && fallbackScreens != nil) {
                let topology = device.deviceTypeIdentifier == SimulatorPose.deviceType && (screens?.count ?? 0) < 2 ? nil : screens
                startNativePreview(udid: bootedDeviceId, session: session, screens: topology)
                return
            }
            // Querying shareable content can ask for screen recording. Defer that decision
            // to an explicit start when the device has no native preview available.
            if !openViewerIfNeeded && !screenRecordingAllowed {
                statusMessage = nil
                await closeInteraction()
                return
            }
            guard !duplicateName else {
                throw SimulatorCaptureService.CaptureError.ambiguousSimulatorName
            }
            guard interaction === session else { return }
            let viewers = try await Self.windowViewers(openIfNeeded: openViewerIfNeeded, accessibilityAllowed: accessibilityAllowed) {
                guard let viewer else { throw SimulatorApplication.LaunchError.viewerUnavailable }
                try await service.openSimulatorApp(udid: bootedDeviceId, using: viewer)
                return viewer.kind
            }
            try Task.checkCancellation()
            guard interaction === session else { return }
            ensureRenderer()
            statusMessage = L10n.tr("Verbindung mit \(device.name) wird hergestellt …")
            try await capture.startCapture(deviceName: device.name, viewers: viewers, retryForWindow: openViewerIfNeeded)
            try Task.checkCancellation()
        } catch {
            await capture.stopCapture()
            guard interaction === session else { return }
            if Task.isCancelled {
                statusMessage = nil
                await closeInteraction()
            } else if !(error is CancellationError) {
                await endWindowCapture(error, deviceID: bootedDeviceId, session: session)
            }
            return
        }

        guard interaction === session else {
            await capture.stopCapture()
            return
        }
        if captureService.isCapturing {
            isCapturing = true
            statusMessage = nil
        }
    }

    /// Device Hub renders foldables in perspective and its remote AX bounds
    /// can belong to either display. Use the verified, flat device framebuffer.
    private func startNativePreview(udid: String, session: DeviceInteractionService, screens: [SimulatorScreen]?) {
        usesNativePreview = true
        usesDeviceHub = false
        viewport = nil
        errorMessage = nil
        isCapturing = true
        statusMessage = nil
        let previewVisible = self.previewVisible
        nativePreviewTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                // Sampling a hidden or completely obscured window adds no visible frames.
                if previewVisible() {
                    do {
                        let frame = try await session.captureActiveScreen(udid: udid, screens: screens)
                        guard let self, !Task.isCancelled, self.interaction === session else { return }
                        if self.devicePointSize != frame.points { self.geometryRevision += 1 }
                        self.devicePointSize = frame.points
                        self.nativeImage = frame.image
                        self.isTouchReady = true
                        self.errorMessage = nil
                        failures = 0
                    } catch {
                        guard let self, !Task.isCancelled, self.interaction === session else { return }
                        if self.isTouchReady { self.geometryRevision += 1 }
                        self.devicePointSize = nil
                        self.nativeImage = nil
                        self.isTouchReady = false
                        let devices = try? await self.listDevices()
                        guard !Task.isCancelled, self.interaction === session else { return }
                        if Self.deviceHasStopped(udid: udid, in: devices) {
                            self.stoppedDeviceID = udid
                            self.isCapturing = false
                            self.errorMessage = nil
                            self.nativePreviewTask = nil // Leaving from this task; never await its own value.
                            await self.closeInteraction()
                            return
                        }
                        self.errorMessage = error.localizedDescription
                        failures = min(failures + 1, 4)
                    }
                }
                // At most one native capture in flight. Back off while iOS is
                // starting or the active surface cannot yet be identified.
                try? await Task.sleep(for: .milliseconds(failures == 0 ? 500 : 800 * failures))
            }
        }
    }

    /// Taps use the geometry that was visible when the gesture began. Drop
    /// gestures that cross a fold, rotation, project change or capture restart.
    func acceptsTouch(udid: String, viewport expected: DeviceHubScreenGeometry.Viewport?, points: CGSize) async -> Bool {
        guard isCapturing, isTouchReady, udid == selectedDeviceID, expected == viewport else { return false }
        let revision = geometryRevision
        if usesNativePreview {
            guard let interaction, points == devicePointSize else { return false }
            let active = try? await interaction.applicationScreenSize(udid: udid)
            return active == points && isTouchReady && self.interaction === interaction && revision == geometryRevision
        }
        guard let expected else { return !usesDeviceHub } // Calibrated classic Simulator window.
        guard points == devicePointSize, let interaction else { return false }
        let native = try? await interaction.activeScreenSize(udid: udid)
        let visible = await captureService.currentDeviceHubViewport()
        guard isCapturing, isTouchReady, udid == selectedDeviceID, revision == geometryRevision else { return false }
        guard visible == expected, native.flatMap({ expected.orientedPoints(for: $0) }) == points else {
            geometryRevision += 1
            devicePointSize = nil
            return false
        }
        return true
    }

    private func closeInteraction() async {
        let preview = nativePreviewTask
        nativePreviewTask = nil
        preview?.cancel()
        let old = interaction
        interaction = nil
        geometryRevision += 1
        usesNativePreview = false
        fallbackScreens = nil
        usesDeviceHub = false
        viewport = nil
        nativeImage = nil
        devicePointSize = nil
        isTouchReady = false
        await old?.shutdown()
        await preview?.value
    }

    /// Full stop: stop SCStream, clear state.
    func stopStreaming() async {
        let capture = captureService
        isCapturing = false
        isPaused = false
        statusMessage = nil
        errorMessage = nil
        needsScreenRecordingPermission = false
        needsAccessibilityPermission = false
        selectedDeviceID = nil
        stoppedDeviceID = nil
        closedWindowDeviceID = nil
        await closeInteraction()
        await capture.stopCapture()
    }

    /// Pause: stop SCStream but keep simulator booted. Lightweight for tab switches.
    func pauseStream() async {
        guard isCapturing || interaction != nil else { return }
        let capture = captureService
        isPaused = true
        isCapturing = false
        await closeInteraction()
        await capture.stopCapture()
    }

    /// Reattach after a pause only to a still-running device and an existing viewer.
    func resumeStream() async {
        guard isPaused else { return }
        await startStreaming(bootedDeviceId: selectedDeviceID, openViewerIfNeeded: false)
    }
}
