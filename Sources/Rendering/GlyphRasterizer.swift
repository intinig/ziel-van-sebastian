import AppKit
import CoreText
import Metal

/// Rasterizes a word via Core Text into an r8Unorm alpha texture.
/// LRU-caches by string+pointSize+kern.
final class GlyphRasterizer {
    private let device: MTLDevice
    private let fontName: String
    private var cache: [String: MTLTexture] = [:]
    private var order: [String] = []
    private let capacity = 64

    init(device: MTLDevice, fontName: String) {
        self.device = device
        self.fontName = fontName
    }

    /// Renders at a fixed large point size; the quad scales to fit on screen.
    /// kern > 0 for letterspaced hints.
    func texture(for text: String, pointSize: CGFloat = 180, kern: CGFloat = 0) -> MTLTexture? {
        let key = "\(text)|\(pointSize)|\(kern)"
        if let hit = cache[key] {
            touch(key)
            return hit
        }

        let font = CTFontCreateWithName(fontName as CFString, pointSize, nil)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            // CT-native key — .foregroundColor ("NSColor") only works via an
            // undocumented AppKit bridge; this one is the documented contract.
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        if kern > 0 { attrs[.kern] = kern }
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        guard width > 0 else { return nil }

        let pad: CGFloat = 8
        let w = Int((width + pad * 2).rounded(.up))
        let h = Int((ascent + descent + pad * 2).rounded(.up))

        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.textPosition = CGPoint(x: pad, y: descent + pad)
        CTLineDraw(line, ctx)

        guard let data = ctx.data else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: w)

        cache[key] = tex
        order.append(key)
        if order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
        return tex
    }

    private func touch(_ key: String) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
    }
}
