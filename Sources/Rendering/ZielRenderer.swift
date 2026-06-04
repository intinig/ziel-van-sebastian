import MetalKit

/// MTKViewDelegate orchestrating the frame: ask the Director for a scene
/// snapshot, draw it. Task 11 version: face only, straight to drawable.
/// Task 15 reroutes through the CRT pipeline.
final class ZielRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let scenePass: ScenePass
    /// Monotonic app clock, shared with the Director's event timestamps.
    let clock: () -> TimeInterval
    /// Pulls the current scene; wired to Director.tick by the app.
    var sceneProvider: (TimeInterval) -> SceneState

    init(device: MTLDevice, pixelFormat: MTLPixelFormat,
         clock: @escaping () -> TimeInterval,
         sceneProvider: @escaping (TimeInterval) -> SceneState) throws {
        self.device = device
        self.queue = device.makeCommandQueue()!
        let library = try device.makeDefaultLibrary(bundle: .main)
        self.scenePass = try ScenePass(device: device, library: library, pixelFormat: pixelFormat)
        self.clock = clock
        self.sceneProvider = sceneProvider
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }

        let now = clock()
        let scene = sceneProvider(now)
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.012, green: 0.012, blue: 0.012, alpha: 1)

        if let encoder = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            let w = Double(view.drawableSize.width)
            let h = Double(view.drawableSize.height)
            drawScene(scene, now: now, encoder: encoder, viewW: w, viewH: h)
            encoder.endEncoding()
        }
        cmd.present(drawable)
        cmd.commit()
    }

    /// Task 11: static face. Animations layer in over Tasks 12–13.
    func drawScene(_ scene: SceneState, now: TimeInterval,
                   encoder: MTLRenderCommandEncoder, viewW: Double, viewH: Double) {
        scenePass.drawFace(encoder: encoder, viewW: viewW, viewH: viewH,
                           tint: scene.tint, alpha: 1.0)
    }
}
