import ApplicationServices
import Foundation

/// Device Hub has independent top and bottom controls. Use the actual screen
/// container rather than applying the old Simulator's bezel estimates.
enum DeviceHubScreenGeometry {
    static func screenRect(processID: pid_t, windowTitle: String, windowFrame: CGRect) throws -> CGRect {
        guard AXIsProcessTrusted() else { throw SimulatorCaptureService.CaptureError.accessibilityDenied }
        let app = AXUIElementCreateApplication(processID)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let matchingWindows = windows.filter { attribute($0, kAXTitleAttribute) as? String == windowTitle }
        guard matchingWindows.count == 1, let window = matchingWindows.first else {
            throw SimulatorCaptureService.CaptureError.deviceScreenNotFound
        }
        var candidates: [CGRect] = []
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 5 else { return }
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let ids = children.compactMap { attribute($0, kAXIdentifierAttribute) as? String }
            // These controls are siblings of the screen, outside its coordinate space.
            if ids.contains("camera.viewfinder"), ids.contains("record.circle") {
                for child in children where attribute(child, kAXRoleAttribute) as? String == kAXGroupRole {
                    if let rect = frame(child), rect.width > 100, rect.height > 100,
                       let normalized = normalizedRect(content: rect, window: windowFrame) {
                        candidates.append(normalized)
                    }
                }
            } else {
                children.forEach { visit($0, depth: depth + 1) }
            }
        }
        visit(window, depth: 0)
        guard candidates.count == 1, let rect = candidates.first else {
            throw SimulatorCaptureService.CaptureError.deviceScreenNotFound
        }
        return rect
    }

    static func normalizedRect(content: CGRect, window: CGRect) -> CGRect? {
        guard window.width > 0, window.height > 0, content.width > 0, content.height > 0,
              window.insetBy(dx: -1, dy: -1).contains(content) else { return nil }
        return CGRect(x: (content.minX - window.minX) / window.width,
                      y: (content.minY - window.minY) / window.height,
                      width: content.width / window.width, height: content.height / window.height)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
