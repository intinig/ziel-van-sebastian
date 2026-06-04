import Foundation

public struct GatewayConfig: Codable, Equatable {
    public var url: String = "ws://127.0.0.1:18789"
    public var token: String = ""

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? url
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? token
    }
}

public struct PacingConfig: Codable, Equatable {
    public var baseMs: Double = 280
    public var perCharMs: Double = 60
    public var charThreshold: Int = 6
    public var sentencePauseMs: Double = 320
    public var clausePauseMs: Double = 150
    public var catchupStart: Int = 10
    public var catchupFull: Int = 80
    public var minFactor: Double = 0.45

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseMs = try c.decodeIfPresent(Double.self, forKey: .baseMs) ?? baseMs
        perCharMs = try c.decodeIfPresent(Double.self, forKey: .perCharMs) ?? perCharMs
        charThreshold = try c.decodeIfPresent(Int.self, forKey: .charThreshold) ?? charThreshold
        sentencePauseMs = try c.decodeIfPresent(Double.self, forKey: .sentencePauseMs) ?? sentencePauseMs
        clausePauseMs = try c.decodeIfPresent(Double.self, forKey: .clausePauseMs) ?? clausePauseMs
        catchupStart = try c.decodeIfPresent(Int.self, forKey: .catchupStart) ?? catchupStart
        catchupFull = try c.decodeIfPresent(Int.self, forKey: .catchupFull) ?? catchupFull
        minFactor = try c.decodeIfPresent(Double.self, forKey: .minFactor) ?? minFactor
    }
}

public struct ShaderConfig: Codable, Equatable {
    public var scanlineIntensity: Double = 0.35
    public var scanlinePitch: Double = 3
    public var maskIntensity: Double = 0.25
    public var bloomStrength: Double = 0.55
    public var curvature: Double = 0.12
    public var vignette: Double = 0.35
    public var flicker: Double = 0.03
    public var noise: Double = 0.04
    public var persistence: Double = 0.82

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scanlineIntensity = try c.decodeIfPresent(Double.self, forKey: .scanlineIntensity) ?? scanlineIntensity
        scanlinePitch = try c.decodeIfPresent(Double.self, forKey: .scanlinePitch) ?? scanlinePitch
        maskIntensity = try c.decodeIfPresent(Double.self, forKey: .maskIntensity) ?? maskIntensity
        bloomStrength = try c.decodeIfPresent(Double.self, forKey: .bloomStrength) ?? bloomStrength
        curvature = try c.decodeIfPresent(Double.self, forKey: .curvature) ?? curvature
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? vignette
        flicker = try c.decodeIfPresent(Double.self, forKey: .flicker) ?? flicker
        noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? noise
        persistence = try c.decodeIfPresent(Double.self, forKey: .persistence) ?? persistence
    }
}

/// Partial shader override from config — only keys present in JSON are set.
/// Applied on top of the active theme's ShaderConfig.
public struct ShaderOverlay: Codable, Equatable {
    public var scanlineIntensity: Double?
    public var scanlinePitch: Double?
    public var maskIntensity: Double?
    public var bloomStrength: Double?
    public var curvature: Double?
    public var vignette: Double?
    public var flicker: Double?
    public var noise: Double?
    public var persistence: Double?

    public init() {}

    public func applied(to base: ShaderConfig) -> ShaderConfig {
        var s = base
        if let v = scanlineIntensity { s.scanlineIntensity = v }
        if let v = scanlinePitch { s.scanlinePitch = v }
        if let v = maskIntensity { s.maskIntensity = v }
        if let v = bloomStrength { s.bloomStrength = v }
        if let v = curvature { s.curvature = v }
        if let v = vignette { s.vignette = v }
        if let v = flicker { s.flicker = v }
        if let v = noise { s.noise = v }
        if let v = persistence { s.persistence = v }
        return s
    }
}

/// Partial look override from config. Values come from the theme named by
/// `theme` (default: Theme.defaultName); any key set here wins over the theme.
/// Synthesized Codable uses decodeIfPresent for optionals — absent keys stay nil.
public struct LookConfig: Codable, Equatable {
    public var theme: String?
    public var idleTint: String?
    public var thinkingTint: String?
    public var speakingTint: String?
    public var fontName: String?
    public var background: String?
    public var shadowColor: String?
    public var shadowOffsetX: Double?
    public var shadowOffsetY: Double?
    public var shader: ShaderOverlay?

    public init() {}
}

public struct BehaviorConfig: Codable, Equatable {
    public var wakingSeconds: Double = 0.8
    public var settlingSeconds: Double = 1.2
    public var dozeAfterSeconds: Double = 600
    public var hintHoldSeconds: Double = 2.5

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wakingSeconds = try c.decodeIfPresent(Double.self, forKey: .wakingSeconds) ?? wakingSeconds
        settlingSeconds = try c.decodeIfPresent(Double.self, forKey: .settlingSeconds) ?? settlingSeconds
        dozeAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .dozeAfterSeconds) ?? dozeAfterSeconds
        hintHoldSeconds = try c.decodeIfPresent(Double.self, forKey: .hintHoldSeconds) ?? hintHoldSeconds
    }
}

public struct DisplayConfig: Codable, Equatable {
    /// Case-insensitive substrings matched against NSScreen.localizedName.
    public var preferredNameContains: [String] = ["wokyis", "m5"]
    public var preventDisplaySleep: Bool = true

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferredNameContains = try c.decodeIfPresent([String].self, forKey: .preferredNameContains) ?? preferredNameContains
        preventDisplaySleep = try c.decodeIfPresent(Bool.self, forKey: .preventDisplaySleep) ?? preventDisplaySleep
    }
}

public struct ZielConfig: Codable, Equatable {
    public var gateway: GatewayConfig = GatewayConfig()
    public var pacing: PacingConfig = PacingConfig()
    public var look: LookConfig = LookConfig()
    public var behavior: BehaviorConfig = BehaviorConfig()
    public var display: DisplayConfig = DisplayConfig()

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gateway = try c.decodeIfPresent(GatewayConfig.self, forKey: .gateway) ?? gateway
        pacing = try c.decodeIfPresent(PacingConfig.self, forKey: .pacing) ?? pacing
        look = try c.decodeIfPresent(LookConfig.self, forKey: .look) ?? look
        behavior = try c.decodeIfPresent(BehaviorConfig.self, forKey: .behavior) ?? behavior
        display = try c.decodeIfPresent(DisplayConfig.self, forKey: .display) ?? display
    }

    public static func decode(_ data: Data) throws -> ZielConfig {
        try JSONDecoder().decode(ZielConfig.self, from: data)
    }

    /// Missing or invalid file → defaults (never fatally); errors will be
    /// logged once os.Logger wiring lands with the config watcher.
    public static func load(from url: URL) -> ZielConfig {
        guard let data = try? Data(contentsOf: url) else { return ZielConfig() }
        // Note: a type mismatch in ANY field throws, discarding the whole file
        // and falling back to full defaults — intentional, not per-field.
        return (try? decode(data)) ?? ZielConfig()
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ziel van Sebastian/config.json")
    }
}
