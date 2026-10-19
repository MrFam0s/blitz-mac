import AppKit
import SwiftUI

/// A native transparent input view above the native Metal renderer.
struct SimulatorTouchSurface: NSViewRepresentable {
    struct Event {
        let startLocation: CGPoint
        let location: CGPoint
    }

    var onChanged: (Event) -> Void
    var onEnded: (Event) -> Void

    func makeNSView(context: Context) -> Surface { Surface() }

    func updateNSView(_ view: Surface, context: Context) {
        view.onChanged = onChanged
        view.onEnded = onEnded
    }

    final class Surface: NSView {
        var onChanged: ((Event) -> Void)?
        var onEnded: ((Event) -> Void)?
        private var start: CGPoint?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            start = point
            onChanged?(Event(startLocation: point, location: point))
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            onChanged?(Event(startLocation: start, location: convert(event.locationInWindow, from: nil)))
        }

        override func mouseUp(with event: NSEvent) {
            guard let start else { return }
            self.start = nil
            onEnded?(Event(startLocation: start, location: convert(event.locationInWindow, from: nil)))
        }
    }
}
