// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation
import ScreenCaptureKit
import CoreVideo
import CoreMedia
import os

private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "SimulatorCapture")

/// ScreenCaptureKit-based simulator frame capture
final class SimulatorCaptureService: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var streamOutput: StreamOutputHandler?
    private var currentWindow: SCWindow?
    private var resizeTimer: Timer?
    @MainActor private var resizeCheckRunning = false

    /// Protects _latestFrame against concurrent read (main thread) / write (capture queue)
    private let frameLock = NSLock()
    private var _latestFrame: CVPixelBuffer?

    /// Latest captured frame — read by MetalRenderer on the main thread
    var latestFrame: CVPixelBuffer? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _latestFrame
    }
    private(set) var frameSize: CGSize = .zero
    private(set) var isCapturing = false
    private(set) var frameCount: Int = 0
    private(set) var deviceScreenRect: CGRect?
    var onGeometryChange: (@MainActor @Sendable (CGRect?) -> Void)?
    var onTouchAvailabilityChange: (@MainActor @Sendable (Bool) -> Void)?

    /// Callback when a new frame arrives
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var skipFrameCount = 0
    private static let fps = 50

    private let simulatorBundleIDs = [
        "com.apple.iphonesimulator",
        "com.apple.CoreSimulator.SimulatorTrampoline",
        "com.apple.dt.Devices"
    ]

    /// Search an already-fetched SCShareableContent for the simulator window.
    private func findSimulatorWindow(in content: SCShareableContent, deviceName: String) -> SCWindow? {
        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            return simulatorBundleIDs.contains(app.bundleIdentifier)
                && window.frame.width >= 200 && window.frame.height >= 300
        }
        guard let index = Self.matchingWindowIndex(titles: candidates.map { $0.title ?? "" }, deviceName: deviceName) else {
            return nil
        }
        return candidates[index]
    }

    /// Never fall back to the first window: input events target a specific UDID.
    static func matchingWindowIndex(titles: [String], deviceName: String) -> Int? {
        let matches = titles.indices.filter { index in
            let title = titles[index]
            return title == deviceName || [" – ", " — ", " - ", " ("].contains {
                title.hasPrefix(deviceName + $0)
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Start capturing the simulator window.
    /// Calls SCShareableContent exactly ONCE. If the window isn't visible yet,
    /// retries the query up to 10 times (1s apart).
    func startCapture(deviceName: String, retryForWindow: Bool = true) async throws {
        guard !isCapturing else {
            logger.warning("Already capturing")
            return
        }

        logger.info("Starting capture at \(Self.fps) FPS...")

        // Step 1: Query SCShareableContent ONCE to get permission sorted out.
        // If this throws, it's a permission error — bail immediately, no retry.
        let initialContent: SCShareableContent
        do {
            initialContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            logger.error("SCShareableContent failed: \(error.localizedDescription)")
            throw CaptureError.screenRecordingDenied(error.localizedDescription)
        }

        // Step 2: Look for the simulator window. If not found, retry (re-querying
        // SCShareableContent is safe AFTER the first successful call — TCC won't re-prompt
        // for the same process once granted).
        var window = findSimulatorWindow(in: initialContent, deviceName: deviceName)

        if window == nil && retryForWindow {
            let maxAttempts = 10
            for attempt in 1...maxAttempts {
                logger.info("Simulator window not found, retrying... (\(attempt)/\(maxAttempts))")
                try await Task.sleep(for: .seconds(1))

                if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                    window = findSimulatorWindow(in: content, deviceName: deviceName)
                    if window != nil { break }
                }
            }
        }

        guard var window = window else {
            throw CaptureError.simulatorWindowNotFound
        }

        try Task.checkCancellation()
        if window.owningApplication?.bundleIdentifier == "com.apple.dt.Devices",
           let app = window.owningApplication {
            let selectedWindowID = window.windowID
            deviceScreenRect = try await DeviceHubScreenGeometry.waitForScreen {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let refreshed = content.windows.first(where: { $0.windowID == selectedWindowID }) else {
                    throw CaptureError.deviceScreenNotFound
                }
                window = refreshed
                return try DeviceHubScreenGeometry.screenRect(
                    processID: app.processID, windowTitle: refreshed.title ?? "", windowFrame: refreshed.frame)
            }
        } else {
            deviceScreenRect = nil
        }
        currentWindow = window
        await onGeometryChange?(deviceScreenRect)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()

        let scale: CGFloat = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.fps))
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false

        logger.info("Stream config: \(config.width)x\(config.height) BGRA")

        let handler = StreamOutputHandler(service: self)
        self.streamOutput = handler

        let stream = SCStream(filter: filter, configuration: config, delegate: handler)
        try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

        do {
            try await stream.startCapture()
        } catch {
            logger.error("startCapture failed: \(error.localizedDescription)")
            throw CaptureError.captureStartFailed(error.localizedDescription)
        }

        self.stream = stream
        self.isCapturing = true
        await onTouchAvailabilityChange?(true)
        self.skipFrameCount = 0
        self.frameCount = 0
        self.frameSize = CGSize(width: config.width, height: config.height)

        logger.info("Capture started successfully")

        // Poll for window resize every second
        await MainActor.run {
            self.resizeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { await self?.checkForResize() }
            }
        }
    }

    /// Stop capturing
    func stopCapture() async {
        logger.info("Stopping capture (total frames: \(self.frameCount))")
        await onTouchAvailabilityChange?(false)

        await MainActor.run {
            resizeTimer?.invalidate()
            resizeTimer = nil
        }

        if let stream {
            try? await stream.stopCapture()
        }

        stream = nil
        streamOutput = nil
        currentWindow = nil
        deviceScreenRect = nil
        await onGeometryChange?(nil)
        isCapturing = false
        clearLatestFrame()
    }

    private func clearLatestFrame() {
        frameLock.lock()
        _latestFrame = nil
        frameLock.unlock()
    }

    /// Refresh only the selected window after capture permission has been granted.
    @MainActor private func checkForResize() async {
        guard !resizeCheckRunning, isCapturing, let previous = currentWindow,
              let expectedStream = stream else { return }
        resizeCheckRunning = true
        defer { resizeCheckRunning = false }
        // Permission has already been granted. Refresh this exact window's geometry.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              var window = content.windows.first(where: { $0.windowID == previous.windowID }),
              stream === expectedStream else { return }
        if window.owningApplication?.bundleIdentifier == "com.apple.dt.Devices",
           let app = window.owningApplication {
            do {
                let rect: CGRect
                do {
                    rect = try DeviceHubScreenGeometry.screenRect(processID: app.processID,
                        windowTitle: window.title ?? "", windowFrame: window.frame)
                } catch SimulatorCaptureService.CaptureError.deviceScreenNotFound {
                    // Device Hub can temporarily replace its remote AX tree even
                    // without resizing. Suspend touches while refreshing the bounds.
                    onTouchAvailabilityChange?(false)
                    rect = try await DeviceHubScreenGeometry.waitForScreen {
                        guard self.stream === expectedStream else { throw CancellationError() }
                        let refreshed = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        guard let candidate = refreshed.windows.first(where: { $0.windowID == previous.windowID }) else {
                            throw CaptureError.deviceScreenNotFound
                        }
                        window = candidate
                        return try DeviceHubScreenGeometry.screenRect(processID: app.processID,
                            windowTitle: candidate.title ?? "", windowFrame: candidate.frame)
                    }
                }
                guard stream === expectedStream else { return }
                deviceScreenRect = rect
                onGeometryChange?(rect)
                onTouchAvailabilityChange?(true)
            } catch {
                guard stream === expectedStream else { return }
                // Stop rather than keep accepting touches with stale screen bounds.
                await stopCapture()
                await onGeometryChange?(.zero)
                return
            }
        }
        guard stream === expectedStream else { return }
        currentWindow = window

        let scale: CGFloat = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        let newWidth = Int(window.frame.width * scale)
        let newHeight = Int(window.frame.height * scale)

        guard newWidth > 0, newHeight > 0,
              newWidth != Int(frameSize.width) || newHeight != Int(frameSize.height) else { return }

        logger.info("Window resized: \(newWidth)x\(newHeight)")
        let config = SCStreamConfiguration()
        config.width = newWidth
        config.height = newHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.fps))
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false

        do {
            try await stream?.updateConfiguration(config)
            frameSize = CGSize(width: newWidth, height: newHeight)
            skipFrameCount = 0
        } catch {
            logger.warning("Failed to update stream config: \(error.localizedDescription)")
        }
    }

    /// Called by StreamOutputHandler when a frame arrives
    fileprivate func handleFrame(_ sampleBuffer: CMSampleBuffer) {
        // Skip first 3 frames (initialization artifacts)
        if skipFrameCount < 3 {
            skipFrameCount += 1
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        frameCount += 1
        if frameCount == 1 {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            logger.info("First frame received: \(w)x\(h)")
        }

        frameLock.lock()
        _latestFrame = pixelBuffer
        frameLock.unlock()
        onFrame?(pixelBuffer)
    }

    /// Called when the stream encounters an error
    fileprivate func handleStreamError(_ error: Error) {
        logger.error("Stream error: \(error.localizedDescription)")
    }

    enum CaptureError: Error, LocalizedError {
        case simulatorWindowNotFound
        case ambiguousSimulatorName
        case screenRecordingDenied(String)
        case captureStartFailed(String)
        case accessibilityDenied
        case deviceScreenNotFound

        var requiresScreenRecordingPermission: Bool {
            if case .screenRecordingDenied = self { return true }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .simulatorWindowNotFound:
                return "Could not uniquely find the selected simulator window. Open that device in a compact Device Hub or Simulator window and try again."
            case .ambiguousSimulatorName:
                return "Multiple running simulators have the same name. Give your project simulator a unique name in Xcode, then retry."
            case .screenRecordingDenied(let msg):
                return "Screen recording permission denied. Grant access in System Settings → Privacy & Security → Screen Recording, then restart Blitz Neo. If the Quit & Restart popup does not appear after enabling the screen recording permission for Blitz Neo, reboot your Mac. (\(msg))"
            case .captureStartFailed(let msg):
                return "Failed to start capture: \(msg)"
            case .accessibilityDenied:
                return "Allow Blitz Neo in System Settings → Privacy & Security → Accessibility so it can locate the device screen inside Device Hub. Then retry."
            case .deviceScreenNotFound:
                return "Could not locate the device screen inside Device Hub. Open the selected device in a compact window and retry."
            }
        }
    }
}

/// SCStream output + delegate handler
private final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private weak var service: SimulatorCaptureService?

    init(service: SimulatorCaptureService) {
        self.service = service
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        service?.handleFrame(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        service?.handleStreamError(error)
    }
}
