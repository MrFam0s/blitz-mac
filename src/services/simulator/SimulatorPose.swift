// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import AppKit
import ApplicationServices

enum SimulatorPose: String, CaseIterable {
    case closed, partiallyOpen, open

    var label: String {
        switch self {
        case .closed: L10n.tr("Geschlossen")
        case .partiallyOpen: L10n.tr("Teilweise geöffnet")
        case .open: L10n.tr("Geöffnet")
        }
    }

    // Device Hub currently exposes English AX descriptions, including on German macOS.
    private var controlNames: [String] {
        switch self {
        case .closed: ["Closed", "Geschlossen"]
        case .partiallyOpen: ["Partially Open", "Teilweise geöffnet"]
        case .open: ["Open", "Geöffnet"]
        }
    }

    static let deviceType = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"

    enum PoseError: LocalizedError {
        case changedTarget, unavailable
        var errorDescription: String? {
            switch self {
            case .changedTarget: L10n.tr("Wähle den laufenden iPhone-Duo-Simulator dieses Projekts.")
            case .unavailable: L10n.tr("Die Faltposition lässt sich in diesem Device-Hub-Fenster nicht einstellen. Öffne das Gerät in Xcode.")
            }
        }
    }

    struct Control {
        let role: String
        let identifier: String?
        let description: String?
        let text: String?
    }

    /// Direct children of the compact window's host group. Never descend into
    /// the mirrored application's accessibility tree when selecting an action.
    func buttonIndex(in controls: [Control], for deviceName: String) -> Int? {
        guard controls.contains(where: { $0.role == "AXStaticText" && $0.text == deviceName }),
              controls.contains(where: { $0.role == "AXButton" && $0.identifier == "camera.viewfinder" }),
              controls.contains(where: { $0.role == "AXButton" && $0.identifier == "record.circle" }) else { return nil }
        let indices = controls.indices.filter { i in
            controls[i].role == "AXButton" && controlNames.contains(controls[i].description ?? "")
        }
        return indices.count == 1 ? indices[0] : nil
    }

    @MainActor func request(in appState: AppState, projectId: String, udid: String) async throws {
        func isBound() -> Bool {
            appState.activeProjectId == projectId && appState.simulatorManager.projectID == projectId
                && appState.simulatorManager.bootedDeviceId == udid
        }
        guard isBound() else { throw PoseError.changedTarget }
        guard AXIsProcessTrusted() else { throw SimulatorCaptureService.CaptureError.accessibilityDenied }

        let service = SimulatorService()
        let devices = try await service.listDevices()
        guard isBound(), let device = devices.first(where: { $0.udid == udid && $0.isBooted }),
              device.deviceTypeIdentifier == Self.deviceType else { throw PoseError.changedTarget }
        guard devices.filter({ $0.isBooted && $0.name == device.name }).count == 1 else {
            throw SimulatorCaptureService.CaptureError.ambiguousSimulatorName
        }
        try await service.openSimulatorApp(udid: udid)
        guard isBound() else { throw PoseError.changedTarget }
        try pressButton(deviceName: device.name)
    }

    @MainActor func pressButton(deviceName: String) throws {
        guard AXIsProcessTrusted() else { throw SimulatorCaptureService.CaptureError.accessibilityDenied }
        let windows = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Devices").flatMap { app in
            attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
        }
        let titles = windows.map { attribute($0, kAXTitleAttribute) as? String ?? "" }
        guard let index = SimulatorCaptureService.matchingWindowIndex(titles: titles, deviceName: deviceName) else {
            throw SimulatorCaptureService.CaptureError.simulatorWindowNotFound
        }
        let groups = attribute(windows[index], kAXChildrenAttribute) as? [AXUIElement] ?? []
        let buttons: [AXUIElement] = groups.compactMap { group in
            guard attribute(group, kAXRoleAttribute) as? String == "AXGroup",
                  let children = attribute(group, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            let controls = children.map { node in
                let role = attribute(node, kAXRoleAttribute) as? String ?? ""
                return Control(role: role, identifier: attribute(node, kAXIdentifierAttribute) as? String,
                               description: role == "AXButton" ? attribute(node, kAXDescriptionAttribute) as? String : nil,
                               text: role == "AXStaticText" ? attribute(node, kAXValueAttribute) as? String : nil)
            }
            return buttonIndex(in: controls, for: deviceName).map { children[$0] }
        }
        guard buttons.count == 1, AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) == .success else {
            throw PoseError.unavailable
        }
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
}
