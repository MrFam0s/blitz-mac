import AppKit
import Foundation

@MainActor
@Observable
final class SimulatorStreamManager {
    let captureService = SimulatorCaptureService()
    private(set) var interaction: DeviceInteractionService?
    private(set) var usesNativePreview = false
    private(set) var nativeImage: CGImage?
    private var nativePreviewTask: Task<Void, Never>?
    private let previewVisible: @MainActor () -> Bool
    var renderer: MetalRenderer?
    var isCapturing = false
    var errorMessage: String?
    private(set) var needsScreenRecordingPermission = false
    private(set) var needsAccessibilityPermission = false
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

    init(previewVisible: @escaping @MainActor () -> Bool = {
        NSApp?.windows.contains { $0.canBecomeMain && $0.occlusionState.contains(.visible) } == true
    }) {
        self.previewVisible = previewVisible
        captureService.onTouchAvailabilityChange = { [weak self] ready in
            guard let self else { return }
            self.isTouchReady = ready
            if !ready, self.devicePointSize != nil {
                self.geometryRevision += 1
                self.devicePointSize = nil
            }
        }
        captureService.onGeometryChange = { [weak self] state in
            await self?.updateGeometry(state)
        }
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
            isCapturing = false
            errorMessage = error.localizedDescription
            if case .accessibilityDenied = error { needsAccessibilityPermission = true }
            await closeInteraction()
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

    /// Full start: ensure renderer, open Simulator.app, connect SCStream.
    func startStreaming(bootedDeviceId: String?) async {
        guard !isCapturing, interaction == nil else { return }
        guard let bootedDeviceId else {
            statusMessage = nil
            return
        }
        let session = DeviceInteractionService()
        interaction = session
        selectedDeviceID = bootedDeviceId

        errorMessage = nil
        needsScreenRecordingPermission = false
        needsAccessibilityPermission = false
        isPaused = false
        statusMessage = L10n.tr("Simulator wird geöffnet …")
        let service = SimulatorService()
        do {
            let devices = try await service.listDevices()
            guard let device = devices.first(where: { $0.udid == bootedDeviceId && $0.isBooted }) else {
                throw SimulatorCaptureService.CaptureError.simulatorWindowNotFound
            }
            let screens = try? await SimctlClient().integratedScreens(udid: bootedDeviceId)
            guard interaction === session, !Task.isCancelled else { throw CancellationError() }
            // During first boot CoreSimulator may advertise a known Duo before
            // both screen descriptors appear. Keep retrying its native displays.
            if (screens?.count ?? 0) > 1 || device.deviceTypeIdentifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo" {
                startNativePreview(udid: bootedDeviceId, session: session, screens: screens)
                return
            }
            ensureRenderer()
            guard devices.filter({ $0.isBooted && $0.name == device.name }).count == 1 else {
                throw SimulatorCaptureService.CaptureError.ambiguousSimulatorName
            }
            guard interaction === session else { return }
            try await service.openSimulatorApp(udid: bootedDeviceId)
            try Task.checkCancellation()
            guard interaction === session else { return }
            statusMessage = L10n.tr("Verbindung mit \(device.name) wird hergestellt …")
            try await captureService.startCapture(deviceName: device.name, retryForWindow: true)
            try Task.checkCancellation()
        } catch {
            guard interaction === session else { return }
            await closeInteraction()
            if Task.isCancelled { await captureService.stopCapture() }
            else {
                errorMessage = error.localizedDescription
                needsScreenRecordingPermission = (error as? SimulatorCaptureService.CaptureError)?.requiresScreenRecordingPermission == true
                if case SimulatorCaptureService.CaptureError.accessibilityDenied = error {
                    needsAccessibilityPermission = true
                }
            }
            statusMessage = nil
            return
        }

        guard interaction === session else {
            if interaction == nil { await captureService.stopCapture() }
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
        isCapturing = true
        statusMessage = nil
        let knownScreens = (screens?.count ?? 0) > 1 ? screens : nil
        let previewVisible = self.previewVisible
        nativePreviewTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                // Sampling a hidden or completely obscured window adds no visible frames.
                if previewVisible() {
                    do {
                        let frame = try await session.captureActiveScreen(udid: udid, screens: knownScreens)
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
        nativeImage = nil
        devicePointSize = nil
        isTouchReady = false
        await old?.shutdown()
        await preview?.value
    }

    /// Full stop: stop SCStream, clear state.
    func stopStreaming() async {
        await closeInteraction()
        await captureService.stopCapture()
        isCapturing = false
        isPaused = false
        statusMessage = nil
        errorMessage = nil
        needsScreenRecordingPermission = false
        needsAccessibilityPermission = false
        selectedDeviceID = nil
    }

    /// Pause: stop SCStream but keep simulator booted. Lightweight for tab switches.
    func pauseStream() async {
        guard isCapturing || interaction != nil else { return }
        isPaused = true
        await closeInteraction()
        await captureService.stopCapture()
        isCapturing = false
    }

    /// Resume: restart SCStream after a pause. No window retry needed since sim is already running.
    func resumeStream() async {
        guard isPaused else { return }
        await startStreaming(bootedDeviceId: selectedDeviceID)
    }
}
