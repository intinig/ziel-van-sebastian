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

public enum ThemeError: Error, Equatable, CustomStringConvertible {
    case unknownTheme(name: String, valid: [String])

    public var description: String {
        switch self {
        case let .unknownTheme(name, valid):
            return "unknown theme '\(name)' — valid themes: \(valid.joined(separator: ", "))"
        }
    }
}

/// The look the app actually runs with: active theme + config overrides,
/// computed once at startup.
public struct ResolvedLook: Equatable {
    public var idleTint: String
    public var thinkingTint: String
    public var speakingTint: String
    public var fontName: String
    public var background: String
    public var shadowColor: String?
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double
    public var shader: ShaderConfig

    /// nil when no shadow color, or when both offsets are zero.
    public var shadow: ShadowSpec? {
        guard let hex = shadowColor, shadowOffsetX != 0 || shadowOffsetY != 0 else { return nil }
        return ShadowSpec(color: ColorRGB(hex: hex), offsetX: shadowOffsetX, offsetY: shadowOffsetY)
    }

    public static func resolve(_ look: LookConfig, themeOverride: String? = nil) throws -> ResolvedLook {
        let name = themeOverride ?? look.theme ?? Theme.defaultName
        guard let theme = Theme.builtIns[name] else {
            throw ThemeError.unknownTheme(name: name, valid: Theme.builtIns.keys.sorted())
        }
        return ResolvedLook(
            idleTint: look.idleTint ?? theme.idleTint,
            thinkingTint: look.thinkingTint ?? theme.thinkingTint,
            speakingTint: look.speakingTint ?? theme.speakingTint,
            fontName: look.fontName ?? theme.fontName,
            background: look.background ?? theme.background,
            shadowColor: look.shadowColor ?? theme.shadowColor,
            shadowOffsetX: look.shadowOffsetX ?? theme.shadowOffsetX,
            shadowOffsetY: look.shadowOffsetY ?? theme.shadowOffsetY,
            shader: (look.shader ?? ShaderOverlay()).applied(to: theme.shader)
        )
    }
}
