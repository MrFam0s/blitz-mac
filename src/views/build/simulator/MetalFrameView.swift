import SwiftUI
import MetalKit
import CoreVideo

/// NSViewRepresentable wrapping MTKView for Metal-rendered simulator frames
struct MetalFrameView: NSViewRepresentable {
    let renderer: MetalRenderer
    let captureService: SimulatorCaptureService
    var cursor: CursorState?
    var cropRect: (x: Double, y: Double, w: Double, h: Double) = (0, 0, 1, 1)

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = renderer.device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.delegate = context.coordinator
        mtkView.layer?.isOpaque = true
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.captureService = captureService
        context.coordinator.cursor = cursor
        context.coordinator.cropRect = cropRect
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        nsView.isPaused = true
        nsView.delegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer, captureService: captureService)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        let renderer: MetalRenderer
        var captureService: SimulatorCaptureService
        var cursor: CursorState?
        var cropRect: (x: Double, y: Double, w: Double, h: Double) = (0, 0, 1, 1)

        init(renderer: MetalRenderer, captureService: SimulatorCaptureService) {
            self.renderer = renderer
            self.captureService = captureService
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pixelBuffer = captureService.latestFrame,
                  let drawable = view.currentDrawable,
                  let renderPass = view.currentRenderPassDescriptor else { return }

            renderer.renderBGRAFrame(
                pixelBuffer: pixelBuffer,
                to: drawable,
                renderPassDescriptor: renderPass,
                cropRect: cropRect,
                cursor: cursor
            )
        }
    }
}
