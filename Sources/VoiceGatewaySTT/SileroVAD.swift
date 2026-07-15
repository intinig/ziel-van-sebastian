import Foundation
import CWhisper

/// Streaming Silero VAD via whisper.cpp's VAD API. Feed consecutive 512-sample
/// (32 ms @ 16 kHz) frames; the internal RNN state carries across calls until reset().
///
/// Note on `whisper_vad_n_probs`/`whisper_vad_probs`: whisper.cpp's
/// `whisper_vad_detect_speech_no_reset` resizes its internal probs buffer to
/// exactly the number of chunks processed *by that call* (n_samples / n_window)
/// — it does not accumulate probs across calls. Only the LSTM hidden/cell state
/// persists across calls (until `whisper_vad_reset_state`). Since we always pass
/// a single 512-sample frame (one Silero window), each call yields exactly one
/// probability, so "the last prob" below is simply that frame's prob.
public final class SileroVAD {
    private let ctx: OpaquePointer

    public init(modelPath: String) throws {
        _ = WhisperLogging.installOnce
        var params = whisper_vad_default_context_params()
        params.use_gpu = false   // tiny model; CPU avoids GPU contention with STT
        guard let ctx = whisper_vad_init_from_file_with_params(modelPath, params) else {
            throw NSError(domain: "SileroVAD", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "failed to load VAD model at \(modelPath)"])
        }
        self.ctx = ctx
    }

    deinit { whisper_vad_free(ctx) }

    public func speechProbability(frame512: [Float]) -> Float {
        let ok = frame512.withUnsafeBufferPointer { buf in
            whisper_vad_detect_speech_no_reset(ctx, buf.baseAddress, Int32(buf.count))
        }
        guard ok, whisper_vad_n_probs(ctx) > 0 else { return 0 }
        // Last probability corresponds to the most recent frame.
        return whisper_vad_probs(ctx)[Int(whisper_vad_n_probs(ctx)) - 1]
    }

    public func reset() { whisper_vad_reset_state(ctx) }
}
