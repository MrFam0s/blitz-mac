import SwiftUI
import MetalKit
import SwiftTerm

/// Main Build tab view — simulator frame display + touch interaction
struct SimulatorView: View {
    @Bindable var appState: AppState

    private var stream: SimulatorStreamManager { appState.simulatorStream }
    @State private var deviceInteraction = DeviceInteractionService()
    @State private var keyMonitor: Any?

    /// Get the device config for the currently booted simulator
    private var deviceConfig: SimulatorDeviceConfig {
        let name = appState.simulatorManager.simulators
            .first(where: { $0.udid == appState.simulatorManager.bootedDeviceId })?
            .displayName
        let config = SimulatorConfigDatabase.config(for: name)
        guard let rect = stream.deviceScreenRect else { return config }
        let landscape = rect.width * frameSize.width > rect.height * frameSize.height
        return SimulatorDeviceConfig(toolbarHeight: 0, toolbarOffset: 0,
                                     widthPoints: landscape ? config.heightPoints : config.widthPoints,
                                     heightPoints: landscape ? config.widthPoints : config.heightPoints,
                                     borderX: 0, borderY: 0)
    }

    /// Current frame dimensions from the capture (pixels)
    private var frameSize: CGSize { stream.captureService.frameSize }

    /// Compute the crop rect from device config + current frame size.
    /// Only crops the toolbar — bezels remain visible (matches blitz-cn).
    private var cropRect: (x: Double, y: Double, w: Double, h: Double) {
        if let rect = stream.deviceScreenRect {
            return (rect.minX, rect.minY, rect.width, rect.height)
        }
        let size = frameSize
        guard size.width > 0, size.height > 0 else {
            return (0, 0, 1, 1)
        }
        return SimulatorConfigDatabase.cropRect(
            config: deviceConfig,
            frameWidth: Int(size.width),
            frameHeight: Int(size.height)
        )
    }

    /// Aspect ratio of the crop region (full width × height-minus-toolbar).
    private var cropAspectRatio: CGFloat {
        let size = frameSize
        guard size.width > 0, size.height > 0 else {
            return deviceConfig.widthPoints / deviceConfig.heightPoints
        }
        let crop = cropRect
        let cropW = crop.w * size.width
        let cropH = crop.h * size.height
        guard cropH > 0 else {
            return deviceConfig.widthPoints / deviceConfig.heightPoints
        }
        return cropW / cropH
    }

    var body: some View {
        VStack(spacing: 0) {
            if let renderer = stream.renderer, stream.isCapturing {
                ZStack {
                    Color.black

                    MetalFrameView(
                        renderer: renderer,
                        captureService: stream.captureService,
                        cursor: nil,
                        cropRect: cropRect
                    )
                    .aspectRatio(cropAspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 32))
                    .overlay(
                        TouchOverlayView(
                            deviceConfig: deviceConfig,
                            frameWidth: Int(frameSize.width),
                            frameHeight: Int(frameSize.height),
                            onTap: { x, y in
                                sendInput(.tap(x: x, y: y))
                            },
                            onSwipe: { fx, fy, tx, ty, duration, delta in
                                sendInput(.swipe(fromX: fx, fromY: fy, toX: tx, toY: ty,
                                                 duration: duration, delta: Double(delta)))
                            },
                            gestureVisualization: appState.gestureVisualization,
                            activeDeviceID: appState.simulatorManager.bootedDeviceId,
                            skin: appState.selectedOverlaySkin
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 32))
                        .allowsHitTesting(stream.isTouchReady)
                    )
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = appState.simulatorManager.errorMessage ?? stream.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    HStack(spacing: 12) {
                        if stream.needsScreenRecordingPermission || stream.needsAccessibilityPermission {
                            Button("Open System Settings") {
                                if stream.needsScreenRecordingPermission {
                                    AppRelaunchService.shared.prepareForScreenRecordingPermissionRestart()
                                }
                                let pane = stream.needsAccessibilityPermission ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                            }
                        }
                        Button("Retry") {
                            Task {
                                await appState.startProjectSimulator()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.simulatorManager.isBooting {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    if let name = appState.simulatorManager.bootingDeviceName {
                        Text("Switching to \(name)...")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Booting simulator...")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "iphone")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    if let statusMessage = stream.statusMessage {
                        ProgressView()
                            .controlSize(.small)
                        Text(statusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(appState.simulatorManager.selectedDeviceID == nil
                             ? "Choose a simulator for this project" : "Simulator ready to start")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        Text("Your device choice is saved per project. Other running simulators stay open.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Start Simulator") {
                            Task {
                                await appState.startProjectSimulator()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.simulatorManager.selectedDeviceID == nil)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
        .task(id: appState.activeProjectId) {
            await appState.startProjectSimulator()
        }
        .onAppear {
            deviceInteraction = DeviceInteractionService()
            stream.ensureRenderer()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
            let interaction = deviceInteraction
            Task { await interaction.shutdown() }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                DeviceSelectorView(appState: appState)
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    sendInput(.button(.home))
                }) {
                    Image(systemName: "house")
                        .padding(.horizontal, 4)
                }
                .help("Home button")
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(TouchOverlaySkin.allCases) { s in
                        Button(action: { appState.selectedOverlaySkin = s }) {
                            if s == appState.selectedOverlaySkin {
                                Label(s.label, systemImage: "checkmark")
                            } else {
                                Label(s.label, systemImage: s.icon)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "paintbrush")
                        .padding(.horizontal, 4)
                }
                .help("Gesture overlay style")
            }

        }
    }

    private func sendInput(_ action: DeviceAction) {
        guard let udid = appState.simulatorManager.bootedDeviceId else { return }
        // Capture the originating session and device before scheduling. A late
        // task must never pick up a newly selected project's service or UDID.
        let interaction = deviceInteraction
        Task { _ = try? await interaction.execute(action, udid: udid) }
    }

    // MARK: - Keyboard Passthrough

    /// HID keycodes for special keys that idb `ui key` accepts
    private static let hidKeycodes: [UInt16: Int] = [
        36: 40,   // Return
        51: 42,   // Backspace/Delete
        48: 43,   // Tab
        53: 41,   // Escape
        123: 80,  // Left arrow
        124: 79,  // Right arrow
        125: 81,  // Down arrow
        126: 82,  // Up arrow
        117: 76,  // Forward Delete
        115: 74,  // Home
        119: 77,  // End
        116: 75,  // Page Up
        121: 78,  // Page Down
        49: 44,   // Space
    ]

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            // Only capture when simulator is streaming and this tab is active
            guard stream.isCapturing,
                  appState.activeTab == .app && appState.activeAppSubTab == .simulator,
                  !appState.ascManager.showAppleIDLogin,
                  let udid = appState.simulatorManager.bootedDeviceId else {
                return event
            }

            // Don't capture if another text-input surface currently owns focus.
            if simulatorKeyPassthroughShouldIgnore(event.window?.firstResponder) {
                return event
            }

            // Ignore modifier-only keys and Cmd-combos (let system handle those)
            if event.modifierFlags.contains(.command) {
                return event
            }

            let interaction = deviceInteraction
            if let hidCode = Self.hidKeycodes[event.keyCode] {
                Task { _ = try? await interaction.execute(.key(.keycode(hidCode)), udid: udid) }
                return nil // consumed
            } else if let chars = event.characters, !chars.isEmpty,
                      chars.unicodeScalars.allSatisfy({ !$0.properties.isNoncharacterCodePoint && $0.value >= 0x20 }) {
                Task { _ = try? await interaction.execute(.inputText(chars), udid: udid) }
                return nil // consumed
            }

            return event
        }
    }

    private func simulatorKeyPassthroughShouldIgnore(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if responder is NSTextView || responder is NSTextField || responder is TerminalView {
            return true
        }

        var view = responder as? NSView
        while let current = view {
            if current is TerminalView {
                return true
            }
            view = current.superview
        }

        return false
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
