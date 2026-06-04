import Foundation

/// Pure functions of time → animation parameters. The renderer evaluates
/// these every frame; no stored animation state anywhere.
public enum FaceAnimation {
    /// Eye openness 0.08…1.0. 7s cycle; a fast dip blink near the end.
    public static func blinkScale(at t: TimeInterval) -> Double {
        let cycle = t.truncatingRemainder(dividingBy: 7.0)
        guard (6.8...7.0).contains(cycle) else { return 1.0 }
        let u = (cycle - 6.8) / 0.2
        let c = cos(u * .pi)
        let openness = c * c
        return max(0.08, openness)
    }

    /// Horizontal wander in grid units, ±1.4, slow drift. 0 at t=0.
    public static func wanderOffset(at t: TimeInterval) -> Double {
        1.4 * sin(t * 2 * .pi / 16.0) * sin(t * 2 * .pi / 7.3)
    }

    /// Whole-face breathing scale, ±2%.
    public static func breatheScale(at t: TimeInterval) -> Double {
        1.0 + 0.02 * sin(t * 2 * .pi / 6.0)
    }

    /// Scanline sweep position 0…1 (top→bottom), period 2.8s.
    public static func sweepY(at t: TimeInterval, period: Double = 2.8) -> Double {
        (t / period).truncatingRemainder(dividingBy: 1.0)
    }

    /// Thinking dots: how many of the three thought-bubble dots are visible.
    /// Hard steps (no easing) over a 2s cycle: blank, 1, 2, 3, blank.
    public static func thinkingDotsVisible(at t: TimeInterval, period: Double = 2.0) -> Int {
        let p = t.truncatingRemainder(dividingBy: period) / period
        switch p {
        case ..<0.15: return 0
        case ..<0.40: return 1
        case ..<0.65: return 2
        case ..<0.85: return 3
        default: return 0
        }
    }

    /// Thinking: eyes drift up-left and back, 5s cycle. Grid units
    /// (pre-breathe space — ScenePass applies breathe after this offset).
    public static func eyesUpOffset(at t: TimeInterval) -> (dx: Double, dy: Double) {
        let u = (sin(t * 2 * .pi / 5.0 - .pi / 2) + 1) / 2
        return (dx: -0.6 * u, dy: -1.0 * u)
    }

    /// Doze z's pulse: slow fade in/out, 4s cycle.
    public static func zzAlpha(at t: TimeInterval) -> Double {
        max(0, sin(t * 2 * .pi / 4.0)) * 0.8
    }

    /// Waking transition: a quick double-blink as a function of phase
    /// progress 0…1. Two full open→closed→open cycles across the transition.
    public static func wakeBlinkScale(progress: Double) -> Double {
        let p = max(0, min(1, progress))
        return max(0.08, abs(cos(p * 2 * .pi)))
    }
}
