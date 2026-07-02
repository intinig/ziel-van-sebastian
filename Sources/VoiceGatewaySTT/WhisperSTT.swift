import Foundation
import CWhisper

/// Thin wrapper over whisper.cpp full-transcription. One instance = one loaded
/// model (load ~70 ms for base.en; keep it alive for the process lifetime).
public final class WhisperSTT {
    private let ctx: OpaquePointer

    public init(modelPath: String) throws {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw NSError(domain: "WhisperSTT", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "failed to load model at \(modelPath)"])
        }
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    public func transcribe(_ samples: [Float]) -> String {
        // whisper wants ≥~1 s of audio; pad short utterances with trailing silence.
        var padded = samples
        if padded.count < 16000 { padded += [Float](repeating: 0, count: 16000 - padded.count) }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.no_timestamps = true
        let rc = padded.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard rc == 0 else { return "" }
        var out = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            out += String(cString: whisper_full_get_segment_text(ctx, i))
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
