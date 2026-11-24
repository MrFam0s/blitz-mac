// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI
import MetalKit
import SwiftTerm
import UniformTypeIdentifiers

/// Main Build tab view — simulator frame display + touch interaction
struct SimulatorView: View {
    @Bindable var appState: AppState

    private var stream: SimulatorStreamManager { appState.simulatorStream }
    @State private var screenshotError: String?
    @State private var savingScreenshot = false
    @State private var keyMonitor: Any?

    private var deviceConfig: SimulatorDeviceConfig? {
        if stream.usesNativePreview || stream.usesDeviceHub {
            guard let points = stream.devicePointSize else { return nil }
            return SimulatorDeviceConfig(toolbarHeight: 0, toolbarOffset: 0,
                                         widthPoints: points.width, heightPoints: points.height,
                                         borderX: 0, borderY: 0)
        }
        guard let device = appState.simulatorManager.simulators.first(where: {
            $0.udid == appState.simulatorManager.bootedDeviceId
        }) else { return nil }
        return device.legacyConfig
    }

    /// Current frame dimensions from the capture (pixels)
    private var frameSize: CGSize {
        if let image = stream.nativeImage { return CGSize(width: image.width, height: image.height) }
        return stream.captureService.frameSize
    }

    /// Compute the crop rect from device config + current frame size.
    /// Only crops the toolbar — bezels remain visible (matches blitz-cn).
    private var cropRect: (x: Double, y: Double, w: Double, h: Double) {
        if let rect = stream.viewport?.crop {
            return (rect.minX, rect.minY, rect.width, rect.height)
        }
        let size = frameSize
        guard size.width > 0, size.height > 0, let deviceConfig else {
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
        if let content = stream.viewport?.contentSize, content.height > 0 {
            return content.width / content.height
        }
        let size = frameSize
        let fallback = deviceConfig.map { $0.widthPoints / $0.heightPoints } ?? 1
        guard size.width > 0, size.height > 0 else { return fallback }
        let crop = cropRect
        let cropW = crop.w * size.width
        let cropH = crop.h * size.height
        guard cropH > 0 else {
            return fallback
        }
        return cropW / cropH
    }

    var body: some View {
        VStack(spacing: 0) {
            if stream.isCapturing {
                ZStack {
                    Color.black

                    Group {
                        if stream.usesNativePreview {
                            if let image = stream.nativeImage {
                                Image(decorative: image, scale: 1).resizable()
                            } else {
                                ProgressView()
                            }
                        } else if let renderer = stream.renderer {
                            MetalFrameView(renderer: renderer, captureService: stream.captureService,
                                           cursor: nil, cropRect: cropRect)
                        }
                    }
                    .aspectRatio(cropAspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: stream.usesNativePreview ? 0 : 32))
                    .overlay {
                        if let deviceConfig {
                            let viewport = stream.viewport
                            TouchOverlayView(
                                deviceConfig: deviceConfig,
                                frameWidth: Int(frameSize.width),
                                frameHeight: Int(frameSize.height),
                                onTap: { x, y in
                                    sendTouch(.tap(x: x, y: y), config: deviceConfig, viewport: viewport)
                                },
                                onSwipe: { fx, fy, tx, ty, duration, delta in
                                    sendTouch(.swipe(fromX: fx, fromY: fy, toX: tx, toY: ty,
                                                     duration: duration, delta: Double(delta)),
                                              config: deviceConfig, viewport: viewport)
                                },
                                gestureVisualization: appState.gestureVisualization,
                                activeDeviceID: appState.simulatorManager.bootedDeviceId,
                                skin: appState.selectedOverlaySkin
                            )
                            .clipShape(RoundedRectangle(cornerRadius: stream.usesNativePreview ? 0 : 32))
                            .allowsHitTesting(stream.isTouchReady)
                            .id(stream.geometryRevision)
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = stream.errorMessage, stream.usesNativePreview {
                    Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                } else if deviceConfig == nil && !stream.usesNativePreview {
                    Text(L10n.tr("Die Touch-Koordinaten sind für diese Ansicht nicht eindeutig. Verwende die Gerätesteuerung in Xcode."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            } else if let errorMessage = appState.simulatorManager.errorMessage ?? stream.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(BlitzLayout.bodyFont)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if stream.needsScreenRecordingPermission || stream.needsAccessibilityPermission {
                            Button(L10n.tr("Systemeinstellungen öffnen")) {
                                if stream.needsScreenRecordingPermission {
                                    AppRelaunchService.shared.prepareForScreenRecordingPermissionRestart()
                                }
                                let pane = stream.needsAccessibilityPermission ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                            }
                        }
                        Button(L10n.tr("Erneut versuchen")) {
                            Task {
                                await appState.startProjectSimulator()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .font(BlitzLayout.toolbarFont)
                    .controlSize(.small)
                }
                .blitzPagePadding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.simulatorManager.isBooting {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    if let name = appState.simulatorManager.bootingDeviceName {
                        Text(L10n.tr("Wechsel zu \(name) …"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.tr("Simulator wird gestartet …"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .blitzPagePadding()
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
                             ? L10n.tr("Wähle einen Simulator für dieses Projekt") : L10n.tr("Simulator ist startbereit"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        Text(L10n.tr("Die Geräteauswahl wird pro Projekt gespeichert. Andere laufende Simulatoren bleiben geöffnet."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(L10n.tr("Simulator starten")) {
                            Task {
                                await appState.startProjectSimulator()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.simulatorManager.selectedDeviceID == nil)
                    }
                }
                .multilineTextAlignment(.center)
                .blitzPagePadding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
        .task(id: appState.activeProjectId) {
            await appState.startProjectSimulator()
        }
        .onAppear {
            stream.ensureRenderer()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
            if let session = stream.interaction {
                Task {
                    guard stream.interaction === session else { return }
                    await stream.pauseStream()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                DeviceSelectorView(appState: appState)
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: saveScreenshot) {
                    Image(systemName: "camera")
                }
                .help(L10n.tr("Screenshot sichern …"))
                .accessibilityLabel(L10n.tr("Screenshot sichern …"))
                .disabled(appState.simulatorManager.bootedDeviceId == nil || savingScreenshot)
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    sendInput(.button(.home))
                }) {
                    Image(systemName: "house")
                        .padding(.horizontal, 4)
                }
                .help(L10n.tr("Home-Taste"))
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
                .help(L10n.tr("Darstellung der Gesten"))
            }

        }
        .alert(L10n.tr("Screenshot sichern …"), isPresented: Binding(
            get: { screenshotError != nil }, set: { if !$0 { screenshotError = nil } }
        )) {} message: {
            Text(screenshotError ?? "")
        }
    }

    @MainActor private func saveScreenshot() {
        guard !savingScreenshot, let udid = appState.simulatorManager.bootedDeviceId else { return }
        let project = appState.activeProjectId
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Screenshot.png"
        panel.title = L10n.tr("Screenshot sichern …")
        guard panel.runModal() == .OK, let destination = panel.url,
              appState.activeProjectId == project, appState.simulatorManager.bootedDeviceId == udid else { return }
        savingScreenshot = true
        Task {
            defer { savingScreenshot = false }
            do {
                try await SimctlClient().screenshot(udid: udid, path: destination.path)
            } catch {
                screenshotError = error.localizedDescription
            }
        }
    }

    private func sendTouch(_ action: DeviceAction, config: SimulatorDeviceConfig,
                           viewport: DeviceHubScreenGeometry.Viewport?) {
        guard let udid = appState.simulatorManager.bootedDeviceId else { return }
        guard let interaction = stream.interaction else { return }
        let points = CGSize(width: config.widthPoints, height: config.heightPoints)
        Task {
            guard await stream.acceptsTouch(udid: udid, viewport: viewport, points: points),
                  appState.simulatorManager.bootedDeviceId == udid else { return }
            _ = try? await interaction.execute(action, udid: udid)
        }
    }

    private func sendInput(_ action: DeviceAction) {
        guard let udid = appState.simulatorManager.bootedDeviceId else { return }
        // Capture the originating session and device before scheduling. A late
        // task must never pick up a newly selected project's service or UDID.
        guard let interaction = stream.interaction else { return }
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

            guard let interaction = stream.interaction else { return event }
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
