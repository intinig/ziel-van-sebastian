import Foundation

/// Hard offset drop shadow. Offsets are in face-grid pixels (the pixel-art
/// unit, `FaceTransform.gridPixel`) so the shadow scales with the display.
public struct ShadowSpec: Equatable {
    public let color: ColorRGB
    public let offsetX: Double
    public let offsetY: Double

    public init(color: ColorRGB, offsetX: Double, offsetY: Double) {
        self.color = color; self.offsetX = offsetX; self.offsetY = offsetY
    }
}

/// A complete, named preset for the app's look. Config `look` keys override
/// the active theme's values (see `ResolvedLook.resolve`).
public struct Theme: Equatable {
    public var idleTint: String
    public var thinkingTint: String
    public var speakingTint: String
    public var fontName: String
    public var background: String
    public var shadowColor: String?
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double
    public var shader: ShaderConfig

    public static let defaultName = "hello"

    public static let builtIns: [String: Theme] = [
        "classic": .classic,
        "hello": .hello,
    ]

    /// Today's green/amber CRT look — must stay pixel-identical (see spec).
    public static let classic = Theme(
        idleTint: "#41ff6a", thinkingTint: "#ffb000", speakingTint: "#e6edf5",
        fontName: "Menlo-Bold", background: "#030303",
        shadowColor: nil, shadowOffsetX: 0, shadowOffsetY: 0,
        shader: ShaderConfig()
    )

    /// Original-Macintosh "hello." look: off-white on dark gray, hard drop
    /// shadow, monochrome CRT (no RGB triads). State is coded by brightness.
    public static let hello: Theme = {
        var shader = ShaderConfig()
        shader.maskIntensity = 0.0
        shader.bloomStrength = 0.4
        return Theme(
            idleTint: "#8a877c", thinkingTint: "#c9c5b8", speakingTint: "#efeadd",
            fontName: "Menlo-Bold", background: "#26271f",
            shadowColor: "#0e0f0b", shadowOffsetX: 0.6, shadowOffsetY: 0.75,
            shader: shader
        )
    }()
}
