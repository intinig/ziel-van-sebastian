import Foundation

/// Fully synthesized sentence: word timings + raw 16-bit little-endian mono PCM,
/// plus a normalized amplitude envelope for the speaking waveform.
public struct SpokenAudio {
    public let requestID: String?     // ElevenLabs request id, for continuity stitching
    public let words: [WordTiming]
    public let pcm: Data
    public let sampleRate: Double
    public let envelope: [Float]      // 0…1 levels at `envelopeRate` Hz
    public let envelopeRate: Double

    public init(requestID: String?, words: [WordTiming], pcm: Data, sampleRate: Double,
                envelope: [Float] = [], envelopeRate: Double = 60) {
        self.requestID = requestID
        self.words = words
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.envelope = envelope
        self.envelopeRate = envelopeRate
    }
}

/// Seam between the coordinator and the real TTS/audio stack.
/// Contract: ALL callbacks must be invoked on the main thread.
public protocol SpeechSynthesizing: AnyObject {
    func fetch(_ request: SpeechRequest, previousRequestIDs: [String],
               completion: @escaping (Result<SpokenAudio, Error>) -> Void)
    /// Only one playback at a time; `onFinished` fires when audio is done.
    func play(_ audio: SpokenAudio, volume: Double,
              onStarted: @escaping () -> Void, onFinished: @escaping () -> Void)
    func stopPlayback()
}
