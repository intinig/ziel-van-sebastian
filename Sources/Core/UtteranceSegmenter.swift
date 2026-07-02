import Foundation

public struct SegmenterConfig: Equatable {
    public var startThreshold: Float = 0.6   // prob ≥ this counts as speech for opening
    public var endThreshold: Float = 0.35    // prob < this counts as silence for closing
    public var startFrames: Int = 3          // consecutive speech frames to open (~96 ms)
    public var hangoverFrames: Int = 25      // trailing silent frames to close (~800 ms)
    public var maxFrames: Int = 940          // hard cap (~30 s) so a stuck-open utterance can't grow unbounded
    public var preRollFrames: Int = 10       // frames of context kept before the opening frame (~320 ms)
    public init() {}
}

/// Pure utterance gate: pushes of (frame, speech-probability) in, utterances out.
/// Counts frames — no clocks — per the Core invariant.
public final class UtteranceSegmenter {
    public enum Event: Equatable { case started, utterance([Float]) }

    public private(set) var isOpen = false
    private let config: SegmenterConfig
    private var preRoll: [[Float]] = []
    private var current: [Float] = []
    private var frameCount = 0
    private var speechStreak = 0
    private var silenceStreak = 0

    public init(config: SegmenterConfig = SegmenterConfig()) { self.config = config }

    public func push(frame: [Float], prob: Float) -> Event? {
        if !isOpen {
            preRoll.append(frame)
            if preRoll.count > config.preRollFrames + config.startFrames { preRoll.removeFirst() }
            speechStreak = prob >= config.startThreshold ? speechStreak + 1 : 0
            if speechStreak >= config.startFrames {
                isOpen = true
                current = preRoll.flatMap { $0 }
                frameCount = preRoll.count
                preRoll = []
                speechStreak = 0
                silenceStreak = 0
                return .started
            }
            return nil
        }
        current += frame
        frameCount += 1
        silenceStreak = prob < config.endThreshold ? silenceStreak + 1 : 0
        if silenceStreak >= config.hangoverFrames || frameCount >= config.maxFrames {
            let samples = current
            resetInternal()
            return .utterance(samples)
        }
        return nil
    }

    public func reset() { resetInternal() }

    private func resetInternal() {
        isOpen = false
        preRoll = []; current = []
        frameCount = 0; speechStreak = 0; silenceStreak = 0
    }
}
