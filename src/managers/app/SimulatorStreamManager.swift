import Foundation

@MainActor
@Observable
final class SimulatorStreamManager {
    let captureService = SimulatorCaptureService()
    var renderer: MetalRenderer?
    var isCapturing = false
    var errorMessage: String?
    var statusMessage: String?
    /// True when the stream was paused by a tab switch (not manually stopped)
    var isPaused = false

    private var rendererInitialized = false
    private var selectedDeviceID: String?

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
            else { errorMessage = error.localizedDescription }
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
