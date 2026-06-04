import MetalKit

/// MTKViewDelegate orchestrating the frame: ask the Director for a scene
/// snapshot, draw it. Task 11 version: face only, straight to drawable.
/// Task 15 reroutes through the CRT pipeline.
final class ZielRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let scenePass: ScenePass
    let glyphs: GlyphRasterizer
    /// Monotonic app clock, shared with the Director's event timestamps.
    let clock: () -> TimeInterval
    /// Pulls the current scene; wired to Director.tick by the app.
    var sceneProvider: (TimeInterval) -> SceneState

    init(device: MTLDevice, pixelFormat: MTLPixelFormat,
         fontName: String,
         clock: @escaping () -> TimeInterval,
         sceneProvider: @escaping (TimeInterval) -> SceneState) throws {
        self.device = device
        self.queue = device.makeCommandQueue()!
        let library = try device.makeDefaultLibrary(bundle: .main)
        self.scenePass = try ScenePass(device: device, library: library, pixelFormat: pixelFormat)
        self.glyphs = GlyphRasterizer(device: device, fontName: fontName)
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

    /// Draws `text` centered at (cx, cy) in NDC, scaled to fit the given
    /// fractions of the view, preserving the texture aspect ratio.
    private func drawText(_ text: String, encoder: MTLRenderCommandEncoder,
                          viewW: Double, viewH: Double,
                          cx: Float, cy: Float, maxWFrac: Double, maxHFrac: Double,
                          tint: ColorRGB, alpha: Double, scale: Double = 1.0,
                          kern: CGFloat = 0) {
        guard let tex = glyphs.texture(for: text, kern: kern) else { return }
        let texW = Double(tex.width), texH = Double(tex.height)
        let maxW = viewW * maxWFrac, maxH = viewH * maxHFrac
        let fit = min(maxW / texW, maxH / texH) * scale
        // NDC half-extents: full width in NDC is 2, so points→NDC = size/view.
        let halfW = Float(texW * fit / viewW)
        let halfH = Float(texH * fit / viewH)
        scenePass.drawGlyphQuad(encoder: encoder, texture: tex,
                                center: (x: cx, y: cy), half: (w: halfW, h: halfH),
                                tint: tint, alpha: alpha)
    }

    /// Task 11: static face. Animations layer in over Tasks 12–13.
    func drawScene(_ scene: SceneState, now: TimeInterval,
                   encoder: MTLRenderCommandEncoder, viewW: Double, viewH: Double) {
        switch scene.phase {
        case .idle, .waking, .offline:
            let dozing = scene.dozing
            let isOffline: Bool
            if case .offline = scene.phase { isOffline = true } else { isOffline = false }
            let blink: Double
            if dozing || isOffline {
                blink = 0.08
            } else if scene.phase == .waking {
                blink = FaceAnimation.wakeBlinkScale(progress: scene.phaseProgress)
            } else {
                blink = FaceAnimation.blinkScale(at: now)
            }
            let wander = (dozing || isOffline || scene.phase == .waking) ? 0 : FaceAnimation.wanderOffset(at: now)
            scenePass.drawFace(encoder: encoder, viewW: viewW, viewH: viewH,
                               tint: scene.tint, alpha: 1.0,
                               faceOffset: (dx: wander, dy: 0),
                               breatheScale: FaceAnimation.breatheScale(at: now),
                               eyeBlinkScale: blink)
            if dozing {
                drawText("z z Z", encoder: encoder, viewW: viewW, viewH: viewH,
                         cx: 0.55, cy: 0.6, maxWFrac: 0.18, maxHFrac: 0.1,
                         tint: scene.tint, alpha: FaceAnimation.zzAlpha(at: now))
            }
            if case .offline(let auth) = scene.phase {
                drawText(auth ? "AUTH" : "OFFLINE",
                         encoder: encoder, viewW: viewW, viewH: viewH,
                         cx: 0, cy: -0.72, maxWFrac: 0.4, maxHFrac: 0.08,
                         tint: scene.tint, alpha: 0.7, kern: 6)
            }

        case .thinking:
            scenePass.drawSweep(encoder: encoder,
                                y: FaceAnimation.sweepY(at: now),
                                tint: scene.tint, intensity: 0.10)
            // Wander intentionally suppressed while thinking — it would fight the eyes-up gesture.
            let up = FaceAnimation.eyesUpOffset(at: now)
            scenePass.drawFace(encoder: encoder, viewW: viewW, viewH: viewH,
                               tint: scene.tint, alpha: 1.0,
                               breatheScale: FaceAnimation.breatheScale(at: now),
                               eyeBlinkScale: FaceAnimation.blinkScale(at: now),
                               eyeOffset: up)
            if let hint = scene.hint {
                drawText(hint, encoder: encoder, viewW: viewW, viewH: viewH,
                         cx: 0, cy: -0.72, maxWFrac: 0.5, maxHFrac: 0.09,
                         tint: scene.tint, alpha: 0.9, kern: 6)
            }

        case .speaking:
            if let word = scene.word {
                // Pop-in: 80ms scale 0.96→1.0, alpha 0.2→1.0.
                let pop = min(1.0, scene.wordAge / 0.08)
                let scale = 0.96 + 0.04 * pop
                let alpha = 0.2 + 0.8 * pop
                drawText(word.uppercased(), encoder: encoder, viewW: viewW, viewH: viewH,
                         cx: 0, cy: 0, maxWFrac: 0.85, maxHFrac: 0.5,
                         tint: scene.tint, alpha: alpha, scale: scale)
            }

        case .settling:
            scenePass.drawFace(encoder: encoder, viewW: viewW, viewH: viewH,
                               tint: scene.tint, alpha: scene.phaseProgress,
                               breatheScale: FaceAnimation.breatheScale(at: now))
        }
    }
}
