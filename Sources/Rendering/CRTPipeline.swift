import MetalKit

/// Owns the offscreen textures and post-process passes:
/// sceneTex → persist (ping-pong) → bright → blurH → blurV → composite.
final class CRTPipeline {
    /// MUST match the Metal CRTParams layout field-for-field.
    struct Params {
        var scanlineIntensity: Float
        var scanlinePitch: Float
        var maskIntensity: Float
        var bloomStrength: Float
        var curvature: Float
        var vignette: Float
        var flicker: Float
        var noise: Float
        var persistence: Float
        var time: Float
        var rippleStrength: Float = 0
        var rippleSpeed: Float = 0
        var rippleLevel: Float = 0
        var rippleEnabled: Float = 0
        var resolution: SIMD2<Float>

        init(_ c: ShaderConfig, time: Float, resolution: SIMD2<Float>) {
            scanlineIntensity = Float(c.scanlineIntensity)
            scanlinePitch = Float(c.scanlinePitch)
            maskIntensity = Float(c.maskIntensity)
            bloomStrength = Float(c.bloomStrength)
            curvature = Float(c.curvature)
            vignette = Float(c.vignette)
            flicker = Float(c.flicker)
            noise = Float(c.noise)
            persistence = Float(c.persistence)
            self.time = time
            self.resolution = resolution
        }
    }

    /// Live-reloaded by the config watcher.
    var shaderConfig: ShaderConfig

    /// Live-reloaded by the config watcher (halo + ripple gating).
    var waveform: WaveformConfig = WaveformConfig()

    private let device: MTLDevice
    private let persistPipeline: MTLRenderPipelineState
    private let brightPipeline: MTLRenderPipelineState
    private let blurHPipeline: MTLRenderPipelineState
    private let blurVPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState

    private(set) var sceneTex: MTLTexture!
    private var phosphorA: MTLTexture!
    private var phosphorB: MTLTexture!
    private var bloomA: MTLTexture!
    private var bloomB: MTLTexture!
    private var pingIsA = true
    private var size: CGSize = .zero
    /// On the first frame after a resize the phosphor textures hold garbage
    /// (dontCare on fresh .private storage). Clear the persist target once
    /// instead of blending the previous frame in.
    private var needsPhosphorClear = false

    init(device: MTLDevice, library: MTLLibrary,
         drawableFormat: MTLPixelFormat, shaderConfig: ShaderConfig) throws {
        assert(MemoryLayout<Params>.stride == 64, "CRTParams layout drifted from Metal struct")
        self.device = device
        self.shaderConfig = shaderConfig

        func pipeline(_ fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        persistPipeline = try pipeline("persist_fragment", format: .bgra8Unorm)
        brightPipeline = try pipeline("bright_fragment", format: .bgra8Unorm)
        blurHPipeline = try pipeline("blur_h_fragment", format: .bgra8Unorm)
        blurVPipeline = try pipeline("blur_v_fragment", format: .bgra8Unorm)
        compositePipeline = try pipeline("composite_fragment", format: drawableFormat)
    }

    func resize(_ newSize: CGSize) {
        guard newSize != size, newSize.width > 0, newSize.height > 0 else { return }
        size = newSize
        func tex(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: max(1, w), height: max(1, h), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        let w = Int(newSize.width), h = Int(newSize.height)
        sceneTex = tex(w, h)
        phosphorA = tex(w, h)
        phosphorB = tex(w, h)
        bloomA = tex(w / 4, h / 4)
        bloomB = tex(w / 4, h / 4)
        needsPhosphorClear = true
    }

    /// Scene already rendered into sceneTex. Runs all post passes and
    /// composites into the drawable's render pass.
    func run(cmd: MTLCommandBuffer, drawableRPD: MTLRenderPassDescriptor, time: Float, level: Float) {
        let (prev, next) = pingIsA ? (phosphorA!, phosphorB!) : (phosphorB!, phosphorA!)
        pingIsA.toggle()
        var params = Params(shaderConfig, time: time,
                            resolution: SIMD2(Float(size.width), Float(size.height)))
        params.rippleEnabled = (waveform.enabled && waveform.ripple.enabled) ? 1 : 0
        params.rippleStrength = Float(waveform.ripple.strength)
        params.rippleSpeed = Float(waveform.ripple.speed)
        params.rippleLevel = level

        func pass(into target: MTLTexture, pipeline: MTLRenderPipelineState,
                  textures: [MTLTexture], loadAction: MTLLoadAction = .dontCare) {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = loadAction
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(pipeline)
            for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
            enc.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // First frame after resize: `prev` holds garbage, so persistence would
        // smear noise across the whole screen. The persist shader still samples
        // `prev`, but with persistence ignored we want a clean base. Zero the
        // prev texture once via a clear-load no-op pass before blending.
        if needsPhosphorClear {
            for t in [phosphorA!, phosphorB!] {
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = t
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                rpd.colorAttachments[0].storeAction = .store
                if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) { enc.endEncoding() }
            }
            needsPhosphorClear = false
        }

        pass(into: next, pipeline: persistPipeline, textures: [sceneTex, prev])
        pass(into: bloomA, pipeline: brightPipeline, textures: [next])
        pass(into: bloomB, pipeline: blurHPipeline, textures: [bloomA])
        pass(into: bloomA, pipeline: blurVPipeline, textures: [bloomB])

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: drawableRPD) else { return }
        enc.setRenderPipelineState(compositePipeline)
        enc.setFragmentTexture(next, index: 0)
        enc.setFragmentTexture(bloomA, index: 1)
        enc.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}
