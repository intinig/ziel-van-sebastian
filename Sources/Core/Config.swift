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

public struct SpeechConfig: Codable, Equatable {
    public var enabled: Bool = false
    public var apiKey: String = ""
    public var voiceId: String = ""
    public var modelId: String = "eleven_flash_v2_5"
    public var languageCode: String? = nil
    public var speed: Double = 1.0
    public var volume: Double = 1.0

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? apiKey
        voiceId = try c.decodeIfPresent(String.self, forKey: .voiceId) ?? voiceId
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId) ?? modelId
        languageCode = try c.decodeIfPresent(String.self, forKey: .languageCode)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? speed
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? volume
    }
}

public struct RippleConfig: Codable, Equatable {
    public var enabled: Bool = true
    public var strength: Double = 0.10
    public var speed: Double = 2.0
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? speed
    }
}

public struct WaveformConfig: Codable, Equatable {
    public var enabled: Bool = true
    public var ripple: RippleConfig = RippleConfig()
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        ripple = try c.decodeIfPresent(RippleConfig.self, forKey: .ripple) ?? ripple
    }
}

public struct VoiceConfig: Codable, Equatable {
    public var enabled: Bool = false
    public var wakeWord: String = "Sebastian"
    public var gatewayURL: String = "ws://127.0.0.1:18790"
    public var model: String = "base.en"
    public var modelPath: String = ""
    public var wakeModelPath: String = ""
    public var vadModelPath: String = ""
    public var wakeThreshold: Double = 0.5
    public var inputDevice: String = ""
    public var outputDevice: String = ""
    public var followUpWindowSeconds: Double = 8
    public var bargeIn: Bool = true
    // Clamp whisper's language auto-detection to this set (e.g. ["it", "en"]).
    // Empty = detect among all ~100 whisper languages (current/default behavior).
    public var languages: [String] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        wakeWord = try c.decodeIfPresent(String.self, forKey: .wakeWord) ?? wakeWord
        gatewayURL = try c.decodeIfPresent(String.self, forKey: .gatewayURL) ?? gatewayURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? modelPath
        wakeModelPath = try c.decodeIfPresent(String.self, forKey: .wakeModelPath) ?? wakeModelPath
        vadModelPath = try c.decodeIfPresent(String.self, forKey: .vadModelPath) ?? vadModelPath
        wakeThreshold = try c.decodeIfPresent(Double.self, forKey: .wakeThreshold) ?? wakeThreshold
        inputDevice = try c.decodeIfPresent(String.self, forKey: .inputDevice) ?? inputDevice
        outputDevice = try c.decodeIfPresent(String.self, forKey: .outputDevice) ?? outputDevice
        followUpWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .followUpWindowSeconds) ?? followUpWindowSeconds
        bargeIn = try c.decodeIfPresent(Bool.self, forKey: .bargeIn) ?? bargeIn
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? languages
    }
}

public struct ZielConfig: Codable, Equatable {
    public var gateway: GatewayConfig = GatewayConfig()
    public var pacing: PacingConfig = PacingConfig()
    public var look: LookConfig = LookConfig()
    public var behavior: BehaviorConfig = BehaviorConfig()
    public var display: DisplayConfig = DisplayConfig()
    public var speech: SpeechConfig = SpeechConfig()
    public var waveform: WaveformConfig = WaveformConfig()
    public var voice: VoiceConfig = VoiceConfig()

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gateway = try c.decodeIfPresent(GatewayConfig.self, forKey: .gateway) ?? gateway
        pacing = try c.decodeIfPresent(PacingConfig.self, forKey: .pacing) ?? pacing
        look = try c.decodeIfPresent(LookConfig.self, forKey: .look) ?? look
        behavior = try c.decodeIfPresent(BehaviorConfig.self, forKey: .behavior) ?? behavior
        display = try c.decodeIfPresent(DisplayConfig.self, forKey: .display) ?? display
        speech = try c.decodeIfPresent(SpeechConfig.self, forKey: .speech) ?? speech
        waveform = try c.decodeIfPresent(WaveformConfig.self, forKey: .waveform) ?? waveform
        voice = try c.decodeIfPresent(VoiceConfig.self, forKey: .voice) ?? voice
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
