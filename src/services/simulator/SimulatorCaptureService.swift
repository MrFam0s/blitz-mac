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
    private var windowTarget: WindowTarget?
    private var resizeTimer: Timer?
    @MainActor private var resizeCheckRunning = false

    /// Protects _latestFrame against concurrent read (main thread) / write (capture queue)
    private let frameLock = NSLock()
    private var _latestFrame: CVPixelBuffer?
    private var acceptingFrames = false

    /// Latest captured frame — read by MetalRenderer on the main thread
    var latestFrame: CVPixelBuffer? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _latestFrame
    }
    private(set) var frameSize: CGSize = .zero
    private(set) var isCapturing = false
    private(set) var frameCount: Int = 0
    enum Geometry: Sendable {
        case classic
        case deviceHub(DeviceHubScreenGeometry.Viewport?)
        case failed(CaptureError)
    }
    var onGeometryChange: (@MainActor @Sendable (Geometry) async -> Void)?
    var onTouchAvailabilityChange: (@MainActor @Sendable (Bool) -> Void)?

    /// Callback when a new frame arrives
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var skipFrameCount = 0
    private static let fps = 50

    struct WindowTarget {
        let id: CGWindowID
        let processID: pid_t
        let deviceName: String

        func matches(id: CGWindowID, processID: pid_t?, title: String?) -> Bool {
            self.id == id && self.processID == processID &&
                SimulatorCaptureService.matchingWindowIndex(titles: [title ?? ""], deviceName: deviceName) != nil
        }

        func window(in content: SCShareableContent) -> SCWindow? {
            content.windows.first { matches(id: $0.windowID, processID: $0.owningApplication?.processID, title: $0.title) }
        }
    }

    /// Search an already-fetched SCShareableContent for the simulator window.
    private func findSimulatorWindow(in content: SCShareableContent, deviceName: String, viewer: SimulatorApplication.Kind) -> SCWindow? {
        let allowed = viewer == .deviceHub ? ["com.apple.dt.Devices"] : ["com.apple.iphonesimulator", "com.apple.CoreSimulator.SimulatorTrampoline"]
        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            return allowed.contains(app.bundleIdentifier) && window.frame.width >= 200 && window.frame.height >= 300
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

    /// Wait for a newly opened viewer, or look once when returning to the tab.
    @MainActor func startCapture(deviceName: String, viewers: [SimulatorApplication.Kind], retryForWindow: Bool) async throws {
        guard !isCapturing else {
            logger.warning("Already capturing")
            return
        }

        logger.info("Starting capture at \(Self.fps) FPS...")

        // A failing WindowServer connection or an empty capture source is distinct from TCC denial.
        let initialContent: SCShareableContent
        do {
            initialContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: retryForWindow)
        } catch {
            logger.error("SCShareableContent failed: \(error.localizedDescription)")
            throw CaptureError.classify(error)
        }

        // Step 2: Look for the simulator window. If not found, retry (re-querying
        // SCShareableContent is safe AFTER the first successful call — TCC won't re-prompt
        // for the same process once granted).
        func matchingWindow(in content: SCShareableContent) -> SCWindow? {
            for viewer in viewers {
                if let window = findSimulatorWindow(in: content, deviceName: deviceName, viewer: viewer) { return window }
            }
            return nil
        }
        var window = matchingWindow(in: initialContent)

        if window == nil && retryForWindow {
            let maxAttempts = 10
            for attempt in 1...maxAttempts {
                logger.info("Simulator window not found, retrying... (\(attempt)/\(maxAttempts))")
                try await Task.sleep(for: .seconds(1))

                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    window = matchingWindow(in: content)
                    if window != nil { break }
                } catch {
                    throw CaptureError.classify(error)
                }
            }
        }

        guard var window, let owner = window.owningApplication else {
            throw retryForWindow ? CaptureError.simulatorWindowNotFound : CaptureError.simulatorWindowClosed
        }

        try Task.checkCancellation()
        let target = WindowTarget(id: window.windowID, processID: owner.processID, deviceName: deviceName)
        if owner.bundleIdentifier == "com.apple.dt.Devices" {
            do {
                let rect = try await DeviceHubScreenGeometry.waitForScreen {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    guard let refreshed = target.window(in: content) else {
                        throw CaptureError.simulatorWindowClosed
                    }
                    window = refreshed
                    return try DeviceHubScreenGeometry.screenRect(
                        processID: owner.processID, windowTitle: refreshed.title ?? "", windowFrame: refreshed.frame)
                }
                await onGeometryChange?(.deviceHub(.init(crop: rect, windowSize: window.frame.size)))
            } catch CaptureError.deviceScreenNotFound {
                // AX can become available after the stream starts. The periodic
                // geometry check enables touches once it identifies one surface.
                await onGeometryChange?(.deviceHub(nil))
            } catch {
                throw await windowFailure(error, target: target)
            }
        } else {
            await onGeometryChange?(.classic)
        }
        windowTarget = target

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
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
        self.stream = stream
        do {
            try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()
        } catch {
            logger.error("startCapture failed: \(error.localizedDescription)")
            throw CaptureError.classify(error)
        }

        guard self.stream === stream else { throw CancellationError() }
        try Task.checkCancellation()
        self.isCapturing = true
        frameLock.withLock { acceptingFrames = true; skipFrameCount = 0; frameCount = 0 }
        onTouchAvailabilityChange?(true)
        self.frameSize = CGSize(width: config.width, height: config.height)

        logger.info("Capture started successfully")

        // Poll for window resize every second
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { await self?.checkForResize() }
        }
        RunLoop.main.add(timer, forMode: .common)
        resizeTimer = timer
    }

    /// Stop capturing
    @MainActor private func detachStream() -> SCStream? {
        let previous = stream
        stream = nil
        streamOutput = nil
        windowTarget = nil
        resizeTimer?.invalidate()
        resizeTimer = nil
        isCapturing = false
        frameSize = .zero
        frameLock.withLock { acceptingFrames = false; _latestFrame = nil }
        onTouchAvailabilityChange?(false)
        return previous
    }

    @MainActor func stopCapture() async {
        let previous = detachStream()
        try? await previous?.stopCapture()
    }

    @MainActor private func endCapture(_ expectedStream: SCStream, failure: CaptureError) async {
        guard stream === expectedStream else { return }
        _ = detachStream()
        await onGeometryChange?(.failed(failure))
        try? await expectedStream.stopCapture()
    }

    private func windowFailure(_ error: Error, target: WindowTarget) async -> CaptureError {
        let failure = CaptureError.classify(error)
        // A window can disappear between the WindowServer snapshot and its AX query.
        // A fresh inventory distinguishes closure from a real AX denial.
        guard failure.requiresAccessibilityPermission else { return failure }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return target.window(in: content) == nil ? .simulatorWindowClosed : failure
        } catch {
            return .classify(error)
        }
    }

    /// Read the same window again at the point of input. The user may have
    /// changed the hinge or rotated the device since the last resize poll.
    @MainActor func currentDeviceHubViewport() async -> DeviceHubScreenGeometry.Viewport? {
        guard let expectedStream = stream, let windowTarget,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              stream === expectedStream,
              let window = windowTarget.window(in: content),
              let app = window.owningApplication, app.bundleIdentifier == "com.apple.dt.Devices",
              let rect = try? DeviceHubScreenGeometry.screenRect(processID: app.processID,
                  windowTitle: window.title ?? "", windowFrame: window.frame) else { return nil }
        return .init(crop: rect, windowSize: window.frame.size)
    }

    /// Refresh only the selected window after capture permission has been granted.
    @MainActor private func checkForResize() async {
        guard !resizeCheckRunning, isCapturing, let windowTarget,
              let expectedStream = stream else { return }
        resizeCheckRunning = true
        defer { resizeCheckRunning = false }
        // Permission has already been granted. Refresh this exact window's geometry.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            await endCapture(expectedStream, failure: .classify(error))
            return
        }
        guard stream === expectedStream else { return }
        guard let window = windowTarget.window(in: content) else {
            await endCapture(expectedStream, failure: .simulatorWindowClosed)
            return
        }
        if window.owningApplication?.bundleIdentifier == "com.apple.dt.Devices",
           let app = window.owningApplication {
            do {
                let rect = try DeviceHubScreenGeometry.screenRect(processID: app.processID,
                    windowTitle: window.title ?? "", windowFrame: window.frame)
                await onGeometryChange?(.deviceHub(.init(crop: rect, windowSize: window.frame.size)))
            } catch CaptureError.deviceScreenNotFound {
                // When Device Hub replaces its remote screen, its AX geometry may
                // briefly disappear. Keep the stream and recover on the next poll.
                onTouchAvailabilityChange?(false)
                return
            } catch {
                let failure = await windowFailure(error, target: windowTarget)
                await endCapture(expectedStream, failure: failure)
                return
            }
        }
        guard stream === expectedStream else { return }
        onTouchAvailabilityChange?(true)

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
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
            try await expectedStream.updateConfiguration(config)
            guard stream === expectedStream else { return }
            frameSize = CGSize(width: newWidth, height: newHeight)
            frameLock.withLock { skipFrameCount = 0 }
        } catch {
            logger.warning("Failed to update stream config: \(error.localizedDescription)")
        }
    }

    /// Called by StreamOutputHandler when a frame arrives
    fileprivate func handleFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.lock()
        guard acceptingFrames else { frameLock.unlock(); return }
        if skipFrameCount < 3 {
            skipFrameCount += 1
            frameLock.unlock()
            return
        }
        frameCount += 1
        if frameCount == 1 {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            logger.info("First frame received: \(w)x\(h)")
        }

        _latestFrame = pixelBuffer
        frameLock.unlock()
        onFrame?(pixelBuffer)
    }

    /// Called when the stream encounters an error
    @MainActor fileprivate func handleStreamError(_ error: Error, stream expectedStream: SCStream) async {
        guard stream === expectedStream else { return }
        logger.error("Stream error: \(error.localizedDescription)")
        var failure = CaptureError.classify(error)
        if let target = windowTarget,
           let inventory = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
           target.window(in: inventory) == nil {
            failure = .simulatorWindowClosed
        }
        await endCapture(expectedStream, failure: failure)
    }

    enum CaptureError: Error, LocalizedError {
        case simulatorWindowNotFound, simulatorWindowClosed
        case ambiguousSimulatorName
        case screenRecordingDenied(String)
        case captureStartFailed(String)
        case accessibilityDenied
        case deviceScreenNotFound

        static func classify(_ error: Error) -> Self {
            if let error = error as? Self { return error }
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain {
                switch nsError.code {
                case SCStreamError.Code.userDeclined.rawValue: return .screenRecordingDenied(error.localizedDescription)
                case SCStreamError.Code.userStopped.rawValue: return .simulatorWindowClosed
                default: break
                }
            }
            return .captureStartFailed(error.localizedDescription)
        }

        var requiresAccessibilityPermission: Bool {
            if case .accessibilityDenied = self { return true }
            return false
        }

        var requiresScreenRecordingPermission: Bool {
            if case .screenRecordingDenied = self { return true }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .simulatorWindowNotFound, .simulatorWindowClosed:
                return L10n.tr("Das ausgewählte Simulatorfenster konnte nicht eindeutig gefunden werden. Öffne dieses Gerät in einem kompakten Device-Hub- oder Simulatorfenster und versuche es erneut.")
            case .ambiguousSimulatorName:
                return L10n.tr("Mehrere laufende Simulatoren haben denselben Namen. Gib dem Projektsimulator in Xcode einen eindeutigen Namen und versuche es erneut.")
            case .screenRecordingDenied(let msg):
                return L10n.tr("Die Bildschirmaufnahme ist nicht erlaubt. Erteile die Freigabe unter Systemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme und starte Blitz Neo neu. Falls macOS danach keinen Neustart von Blitz Neo anbietet, starte den Mac neu. (\(msg))")
            case .captureStartFailed(let msg):
                return L10n.tr("Die Bildschirmaufnahme konnte nicht gestartet werden: \(msg)")
            case .accessibilityDenied:
                return L10n.tr("Erlaube Blitz Neo unter Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen den Zugriff, damit es den Gerätebildschirm im Device Hub finden kann. Versuche es anschließend erneut.")
            case .deviceScreenNotFound:
                return L10n.tr("Der Gerätebildschirm im Device Hub wurde nicht gefunden. Öffne das ausgewählte Gerät in einem kompakten Fenster und versuche es erneut.")
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
        Task { @MainActor [weak service] in await service?.handleStreamError(error, stream: stream) }
    }
}
