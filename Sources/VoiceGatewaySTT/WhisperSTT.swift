import Foundation
import CWhisper

/// Thin wrapper over whisper.cpp full-transcription. One instance = one loaded
/// model (load ~70 ms for base.en; keep it alive for the process lifetime).
public final class WhisperSTT {
    private let ctx: OpaquePointer
    // Whisper language ids from `voice.languages`, resolved once at init.
    // Empty = pure auto-detect across all ~100 whisper languages (current/default behavior).
    private let allowedLangIDs: [Int32]

    public init(modelPath: String, languages: [String] = []) throws {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw NSError(domain: "WhisperSTT", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "failed to load model at \(modelPath)"])
        }
        self.ctx = ctx

        // English-only (*.en) models have exactly one language; there's nothing
        // to clamp, and validating codes against them would just warn-spam for
        // no benefit. Treat as auto (the only option) regardless of `languages`.
        guard !languages.isEmpty, whisper_is_multilingual(ctx) != 0 else {
            self.allowedLangIDs = []
            return
        }

        var ids: [Int32] = []
        var unknown: [String] = []
        for lang in languages {
            let id = whisper_lang_id(lang)
            if id >= 0 { ids.append(id) } else { unknown.append(lang) }
        }
        if !unknown.isEmpty {
            let msg = "[WhisperSTT] unknown language code(s) in voice.languages, ignoring: \(unknown.joined(separator: ", "))\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
        self.allowedLangIDs = ids
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
        // whisper.cpp defaults language to "en"; nil = auto-detect per utterance
        // so multilingual models (voice.model: "base") can hear Italian too.
        // English-only *.en models ignore this and stay English.
        params.language = nil

        if !allowedLangIDs.isEmpty {
            // Clamp: detect language ourselves and pick the best-scoring allowed
            // id, so whisper_full's own (unrestricted) auto-detect never runs.
            // Falls back to unclamped auto-detect (nil) if detection fails.
            params.language = detectAllowedLanguage(in: padded, nThreads: params.n_threads) ?? params.language
        }

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

    // Runs whisper's own mel + language-auto-detect step ahead of whisper_full,
    // then picks the highest-probability id among `allowedLangIDs` only.
    // whisper_lang_str's returned C string is a pointer into a static table in
    // whisper.cpp (g_lang, function-local `static const std::map`), so it lives
    // for the process lifetime — safe to hand straight to whisper_full via
    // params.language without copying.
    private func detectAllowedLanguage(in samples: [Float], nThreads: Int32) -> UnsafePointer<CChar>? {
        let melRC = samples.withUnsafeBufferPointer { buf in
            whisper_pcm_to_mel(ctx, buf.baseAddress, Int32(buf.count), nThreads)
        }
        guard melRC == 0 else { return nil }
        var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        let rc = probs.withUnsafeMutableBufferPointer { probBuf in
            whisper_lang_auto_detect(ctx, 0, nThreads, probBuf.baseAddress)
        }
        guard rc >= 0 else { return nil }
        guard let bestID = allowedLangIDs.max(by: { probs[Int($0)] < probs[Int($1)] }) else { return nil }
        return whisper_lang_str(bestID)
    }
}
