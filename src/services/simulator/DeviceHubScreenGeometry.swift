import ApplicationServices
import Foundation
import os

/// Device Hub has independent top and bottom controls. Use the actual screen
/// container rather than applying the old Simulator's bezel estimates.
enum DeviceHubScreenGeometry {
    private static let logger = Logger(subsystem: "com.blitz.macos", category: "DeviceHubGeometry")

    static func screenRect(processID: pid_t, windowTitle: String, windowFrame: CGRect) throws -> CGRect {
        guard AXIsProcessTrusted() else { throw SimulatorCaptureService.CaptureError.accessibilityDenied }
        let app = AXUIElementCreateApplication(processID)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        // ScreenCaptureKit and accessibility can expose different window titles.
        // The selected window's global bounds also identify its AX counterpart.
        let matchingWindows = windows.filter {
            attribute($0, kAXTitleAttribute) as? String == windowTitle
                || frame($0).map { matchesWindow($0, windowFrame) } == true
        }
        guard matchingWindows.count == 1, let window = matchingWindows.first else {
            logger.error("Could not uniquely match Device Hub AX window (windows: \(windows.count), matches: \(matchingWindows.count))")
            throw SimulatorCaptureService.CaptureError.deviceScreenNotFound
        }
        let candidates = screenBounds(in: window, children: {
            attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }, identifier: {
            attribute($0, kAXIdentifierAttribute) as? String
        }, frame: frame).compactMap { normalizedRect(content: $0, window: windowFrame) }
        guard candidates.count == 1, let rect = candidates.first else {
            logger.error("Could not uniquely find Device Hub screen (candidates: \(candidates.count))")
            logGeometry(window, depth: 0)
            throw SimulatorCaptureService.CaptureError.deviceScreenNotFound
        }
        return rect
    }

    static func matchesWindow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2
            && abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }

    /// SwiftUI's screen container can use different AX roles. Identify it by
    /// its relationship to the compact-window controls and its content instead.
    static func screenBounds<Element>(in root: Element,
        children: (Element) -> [Element], identifier: (Element) -> String?,
        frame: (Element) -> CGRect?) -> [CGRect] {
        var candidates: [CGRect] = []
        func visit(_ element: Element, depth: Int) {
            guard depth < 5 else { return }
            let descendants = children(element)
            let ids = descendants.compactMap(identifier)
            // These controls are siblings of the screen, outside its coordinate space.
            if ids.contains("camera.viewfinder"), ids.contains("record.circle") {
                for child in descendants where !children(child).isEmpty {
                    if let rect = frame(child), rect.width > 100, rect.height > 100 {
                        candidates.append(rect)
                    }
                }
            } else {
                descendants.forEach { visit($0, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return candidates
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

    /// Only structural diagnostics; never log screen text or control values.
    private static func logGeometry(_ element: AXUIElement, depth: Int) {
        guard depth < 3 else { return }
        let role = attribute(element, kAXRoleAttribute) as? String ?? "unknown"
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        let bounds = frame(element).map { NSStringFromRect($0) } ?? "unavailable"
        logger.notice("AX geometry depth=\(depth) role=\(role, privacy: .public) children=\(children.count) frame=\(bounds, privacy: .public)")
        children.forEach { logGeometry($0, depth: depth + 1) }
    }
}
