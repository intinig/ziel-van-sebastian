import Foundation

/// Windowed RMS of 16-bit little-endian mono PCM → normalized amplitude levels
/// (0…1), `rate` samples per second. Pure function: drives the speaking waveform
/// from the real voice, sampled later by the audio clock in the Director.
public enum AmplitudeEnvelope {
    public static func from(pcm: Data, sampleRate: Double, rate: Double = 60) -> [Float] {
        let frameCount = pcm.count / 2
        guard frameCount > 0, sampleRate > 0, rate > 0 else { return [] }
        let window = max(1, Int((sampleRate / rate).rounded()))
        let windowCount = (frameCount + window - 1) / window   // ceil, ≥1
        var out = [Float](); out.reserveCapacity(windowCount)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for w in 0..<windowCount {
                let start = w * window
                let end = min(start + window, frameCount)
                var sumSq = 0.0
                for i in start..<end {
                    let v = Double(Int16(littleEndian: s[i])) / 32768.0
                    sumSq += v * v
                }
                let rms = end > start ? (sumSq / Double(end - start)).squareRoot() : 0
                out.append(Float(min(1.0, rms * 3.5)))   // soft gain so speech reads lively
            }
        }
        return out
    }
}
