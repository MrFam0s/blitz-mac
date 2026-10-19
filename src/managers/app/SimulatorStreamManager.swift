import Foundation

@MainActor
@Observable
final class SimulatorStreamManager {
    let captureService = SimulatorCaptureService()
    var renderer: MetalRenderer?
    var isCapturing = false
    var errorMessage: String?
    private(set) var needsScreenRecordingPermission = false
    private(set) var needsAccessibilityPermission = false
    private(set) var deviceScreenRect: CGRect?
    private(set) var isTouchReady = false
    var statusMessage: String?
    /// True when the stream was paused by a tab switch (not manually stopped)
    var isPaused = false

    private var rendererInitialized = false
    private var selectedDeviceID: String?

    init() {
        captureService.onTouchAvailabilityChange = { [weak self] ready in
            self?.isTouchReady = ready
        }
        captureService.onGeometryChange = { [weak self] rect in
            guard let self else { return }
            if rect == .zero {
                self.isCapturing = false
                self.errorMessage = SimulatorCaptureService.CaptureError.deviceScreenNotFound.localizedDescription
            } else {
                self.deviceScreenRect = rect
            }
        }
    }

    func ensureRenderer() {
        guard !rendererInitialized else { return }
        rendererInitialized = true
        do {
            renderer = try MetalRenderer()
        } catch {
            errorMessage = "Metal init failed: \(error.localizedDescription)"
        }
    }

    /// Full start: ensure renderer, open Simulator.app, connect SCStream.
    func startStreaming(bootedDeviceId: String?) async {
        guard !isCapturing else { return }
        guard let bootedDeviceId else {
            statusMessage = nil
            return
        }
        selectedDeviceID = bootedDeviceId

        errorMessage = nil
        needsScreenRecordingPermission = false
        needsAccessibilityPermission = false
        isPaused = false
        ensureRenderer()

        statusMessage = "Opening Simulator.app..."
        let service = SimulatorService()
        do {
            let devices = try await service.listDevices()
            guard let device = devices.first(where: { $0.udid == bootedDeviceId && $0.isBooted }) else {
                throw SimulatorCaptureService.CaptureError.simulatorWindowNotFound
            }
            guard devices.filter({ $0.isBooted && $0.name == device.name }).count == 1 else {
                throw SimulatorCaptureService.CaptureError.ambiguousSimulatorName
            }
            try await service.openSimulatorApp(udid: bootedDeviceId)
            try Task.checkCancellation()
            statusMessage = "Connecting to \(device.name)..."
            try await captureService.startCapture(deviceName: device.name, retryForWindow: true)
            try Task.checkCancellation()
        } catch {
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

        if captureService.isCapturing {
            isCapturing = true
            statusMessage = nil
        }
    }

    /// Full stop: stop SCStream, clear state.
    func stopStreaming() async {
        await captureService.stopCapture()
        isCapturing = false
        isPaused = false
        statusMessage = nil
        errorMessage = nil
        needsScreenRecordingPermission = false
        needsAccessibilityPermission = false
        deviceScreenRect = nil
    }

    /// Pause: stop SCStream but keep simulator booted. Lightweight for tab switches.
    func pauseStream() async {
        guard isCapturing else { return }
        isPaused = true
        await captureService.stopCapture()
        isCapturing = false
    }

    /// Resume: restart SCStream after a pause. No window retry needed since sim is already running.
    func resumeStream() async {
        guard isPaused else { return }
        await startStreaming(bootedDeviceId: selectedDeviceID)
    }
}
