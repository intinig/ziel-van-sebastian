import Foundation

public struct ColorRGB: Equatable {
    public var r, g, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    /// Parses "#rrggbb" (leading '#' optional). Invalid input → white.
    public init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self.init(r: 1, g: 1, b: 1); return
        }
        self.init(
            r: Double((v >> 16) & 0xff) / 255.0,
            g: Double((v >> 8) & 0xff) / 255.0,
            b: Double(v & 0xff) / 255.0
        )
    }

    public static func lerp(_ a: ColorRGB, _ b: ColorRGB, _ t: Double) -> ColorRGB {
        let u = max(0, min(1, t))
        return ColorRGB(r: a.r + (b.r - a.r) * u, g: a.g + (b.g - a.g) * u, b: a.b + (b.b - a.b) * u)
    }

    public func scaled(_ f: Double) -> ColorRGB { ColorRGB(r: r * f, g: g * f, b: b * f) }
}

public enum Phase: Equatable {
    case idle
    case waking
    case thinking
    case speaking
    case settling
    case offline(auth: Bool)
}

/// Immutable per-frame snapshot the renderer consumes. Pure data.
public struct SceneState: Equatable {
    public let phase: Phase
    /// 0…1 within timed transitions (waking/settling); 1 elsewhere.
    public let phaseProgress: Double
    public let timeInPhase: TimeInterval
    /// Current RSVP word (speaking) — nil otherwise.
    public let word: String?
    /// Seconds the current word has been on screen (drives the pop-in).
    public let wordAge: TimeInterval
    /// Activity hint ("READING…") — populated only in waking/thinking.
    public let hint: String?
    public let dozing: Bool
    public let tint: ColorRGB

    public init(phase: Phase, phaseProgress: Double, timeInPhase: TimeInterval,
                word: String?, wordAge: TimeInterval, hint: String?,
                dozing: Bool, tint: ColorRGB) {
        self.phase = phase; self.phaseProgress = phaseProgress
        self.timeInPhase = timeInPhase; self.word = word; self.wordAge = wordAge
        self.hint = hint; self.dozing = dozing; self.tint = tint
    }
}
