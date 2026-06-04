import MetalKit

/// Renders SceneState content (face, sweep, word, hint) into the current
/// render encoder. Pure geometry assembly — no effects.
final class ScenePass {
    private let device: MTLDevice
    private let flatPipeline: MTLRenderPipelineState
    private let texPipeline: MTLRenderPipelineState
    private let shadow: ShadowSpec?

    struct TexQuadVertex {
        var x, y, u, v: Float
    }

    init(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat,
         shadow: ShadowSpec?) throws {
        self.device = device
        self.shadow = shadow

        func makePipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = pixelFormat
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        flatPipeline = try makePipeline(vertex: "flat_vertex", fragment: "flat_fragment")
        texPipeline = try makePipeline(vertex: "texquad_vertex", fragment: "texquad_fragment")
    }

    /// Face transform: grid units → view points, pixel-snapped, face spans
    /// 60% of view height, centered.
    struct FaceTransform {
        let originX, originY, gridPixel: Double
        let viewW, viewH: Double

        init(viewW: Double, viewH: Double) {
            self.viewW = viewW
            self.viewH = viewH
            let gp = (viewH * 0.6 / Double(FaceGeometry.gridHeight)).rounded(.down)
            gridPixel = max(1, gp)
            originX = ((viewW - gridPixel * Double(FaceGeometry.gridWidth)) / 2).rounded()
            originY = ((viewH - gridPixel * Double(FaceGeometry.gridHeight)) / 2).rounded()
        }
    }

    /// Shadow offset in NDC for the current view size, plus the shadow color.
    /// Offsets are face-grid pixels; NDC spans 2.0 across the view; screen y
    /// grows down while NDC y grows up — hence the negated dy.
    private func shadowDeltaNDC(viewW: Double, viewH: Double) -> (dx: Float, dy: Float, color: ColorRGB)? {
        guard let s = shadow else { return nil }
        let gp = FaceTransform(viewW: viewW, viewH: viewH).gridPixel
        return (dx: Float(s.offsetX * gp / viewW * 2),
                dy: Float(-(s.offsetY * gp / viewH * 2)),
                color: s.color)
    }

    /// offsets in grid units; scales are multipliers around centers.
    /// eyeOffset is in PRE-breathe grid space — breathe scaling is applied after, so offsets amplify by ±2% at breathe extremes (intentional, imperceptible).
    func drawFace(encoder: MTLRenderCommandEncoder,
                  viewW: Double, viewH: Double,
                  tint: ColorRGB, alpha: Double,
                  faceOffset: (dx: Double, dy: Double) = (0, 0),
                  breatheScale: Double = 1.0,
                  eyeBlinkScale: Double = 1.0,
                  eyeOffset: (dx: Double, dy: Double) = (0, 0)) {
        let t = FaceTransform(viewW: viewW, viewH: viewH)
        var verts: [Float] = []

        let faceCenterX = Double(FaceGeometry.gridWidth) / 2
        let faceCenterY = Double(FaceGeometry.gridHeight) / 2

        for rect in FaceGeometry.all {
            let isEye = FaceGeometry.eyes.contains(rect)
            var x0 = Double(rect.x)
            var y0 = Double(rect.y)
            var x1 = Double(rect.x + rect.w)
            var y1 = Double(rect.y + rect.h)

            if isEye {
                // Blink: squash vertically around the eye's own center.
                let cy = (y0 + y1) / 2
                y0 = cy + (y0 - cy) * eyeBlinkScale
                y1 = cy + (y1 - cy) * eyeBlinkScale
                x0 += eyeOffset.dx; x1 += eyeOffset.dx
                y0 += eyeOffset.dy; y1 += eyeOffset.dy
            }

            // Breathe: scale all geometry around the face center.
            func scaled(_ v: Double, around c: Double) -> Double { c + (v - c) * breatheScale }
            x0 = scaled(x0, around: faceCenterX); x1 = scaled(x1, around: faceCenterX)
            y0 = scaled(y0, around: faceCenterY); y1 = scaled(y1, around: faceCenterY)

            x0 += faceOffset.dx; x1 += faceOffset.dx
            y0 += faceOffset.dy; y1 += faceOffset.dy

            // Grid → view points → NDC. Grid y grows downward; NDC y grows upward.
            let px0 = t.originX + x0 * t.gridPixel
            let px1 = t.originX + x1 * t.gridPixel
            let py0 = t.originY + y0 * t.gridPixel
            let py1 = t.originY + y1 * t.gridPixel
            let nx0 = Float(px0 / viewW * 2 - 1)
            let nx1 = Float(px1 / viewW * 2 - 1)
            let ny0 = Float(1 - py0 / viewH * 2)
            let ny1 = Float(1 - py1 / viewH * 2)

            verts += [nx0, ny0, nx1, ny0, nx0, ny1,
                      nx1, ny0, nx1, ny1, nx0, ny1]
        }

        encoder.setRenderPipelineState(flatPipeline)
        if let d = shadowDeltaNDC(viewW: viewW, viewH: viewH) {
            var shadowVerts = verts
            for i in stride(from: 0, to: shadowVerts.count, by: 2) {
                shadowVerts[i] += d.dx
                shadowVerts[i + 1] += d.dy
            }
            var shadowColor: [Float] = [Float(d.color.r), Float(d.color.g), Float(d.color.b), Float(alpha)]
            encoder.setVertexBytes(shadowVerts, length: shadowVerts.count * MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentBytes(&shadowColor, length: 16, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: shadowVerts.count / 2)
        }
        var color: [Float] = [Float(tint.r), Float(tint.g), Float(tint.b), Float(alpha)]
        encoder.setVertexBytes(verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&color, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count / 2)
    }

    /// y in 0…1 from top; draws a soft horizontal band (thinking sweep).
    func drawSweep(encoder: MTLRenderCommandEncoder, y: Double,
                   tint: ColorRGB, intensity: Double) {
        let bandH: Float = 0.12
        let cy = Float(1 - y * 2)
        let verts: [Float] = [
            -1, cy - bandH, 1, cy - bandH, -1, cy + bandH,
            1, cy - bandH, 1, cy + bandH, -1, cy + bandH,
        ]
        var color: [Float] = [Float(tint.r), Float(tint.g), Float(tint.b), Float(intensity)]
        encoder.setRenderPipelineState(flatPipeline)
        encoder.setVertexBytes(verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&color, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// Textured quad centered at NDC (cx, cy) with half-extents (hw, hh).
    func drawGlyphQuad(encoder: MTLRenderCommandEncoder, texture: MTLTexture,
                       center: (x: Float, y: Float), half: (w: Float, h: Float),
                       tint: ColorRGB, alpha: Double,
                       viewW: Double, viewH: Double) {
        if let d = shadowDeltaNDC(viewW: viewW, viewH: viewH) {
            emitGlyphQuad(encoder: encoder, texture: texture,
                          center: (x: center.x + d.dx, y: center.y + d.dy), half: half,
                          rgba: [Float(d.color.r), Float(d.color.g), Float(d.color.b), Float(alpha)])
        }
        emitGlyphQuad(encoder: encoder, texture: texture, center: center, half: half,
                      rgba: [Float(tint.r), Float(tint.g), Float(tint.b), Float(alpha)])
    }

    private func emitGlyphQuad(encoder: MTLRenderCommandEncoder, texture: MTLTexture,
                               center: (x: Float, y: Float), half: (w: Float, h: Float),
                               rgba: [Float]) {
        // Texture v=0 is the TOP of the glyph (Metal texture origin top-left), while NDC y grows upward — hence v flipped relative to y.
        let v: [TexQuadVertex] = [
            .init(x: center.x - half.w, y: center.y - half.h, u: 0, v: 1),
            .init(x: center.x + half.w, y: center.y - half.h, u: 1, v: 1),
            .init(x: center.x - half.w, y: center.y + half.h, u: 0, v: 0),
            .init(x: center.x + half.w, y: center.y - half.h, u: 1, v: 1),
            .init(x: center.x + half.w, y: center.y + half.h, u: 1, v: 0),
            .init(x: center.x - half.w, y: center.y + half.h, u: 0, v: 0),
        ]
        var color = rgba
        encoder.setRenderPipelineState(texPipeline)
        encoder.setVertexBytes(v, length: v.count * MemoryLayout<TexQuadVertex>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&color, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
