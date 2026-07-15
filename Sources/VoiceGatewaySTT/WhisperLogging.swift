import Foundation
import CWhisper

/// Silences whisper.cpp's default per-frame stderr chatter (e.g.
/// `whisper_vad_detect_speech_no_reset: ...` logged on every 32 ms VAD frame),
/// which otherwise grows the deployed voice-gateway log by >20 MB/day.
///
/// `whisper_log_set` forwards to `ggml_log_set` internally (see
/// `whisper.cpp`'s `whisper_log_set`, which calls `ggml_log_set` with the same
/// callback/user_data — and `whisper_backend_init_gpu` re-applies it on every
/// context init), so installing one callback here silences both whisper's own
/// logging and ggml's. There is no separate ggml-only log stream to hook.
///
/// Default: drop everything below `GGML_LOG_LEVEL_WARN`. Set
/// `ZIEL_VOICE_DEBUG=1` to pass every level through to stderr for debugging.
/// The service's own `[voice-gateway]` lines (written directly via
/// `FileHandle.standardError`, not through whisper) are unaffected either way.
enum WhisperLogging {
    // Read once at install time (not captured by the C callback below, which
    // must not close over any context to be convertible to a C function
    // pointer) — a static let is safe to reference from that closure because
    // it is global storage, not a capture.
    private static let passThroughAll = ProcessInfo.processInfo.environment["ZIEL_VOICE_DEBUG"] == "1"

    /// Installs the log callback exactly once for the process. Callers (each
    /// whisper-context-owning type's init) invoke `_ = WhisperLogging.installOnce`
    /// before creating any whisper/VAD context; Swift's `static let` is
    /// lazily and thread-safely initialized exactly once, so redundant calls
    /// from multiple init sites are harmless.
    static let installOnce: Void = {
        whisper_log_set({ level, text, _ in
            guard WhisperLogging.passThroughAll || level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue else { return }
            guard let text else { return }
            FileHandle.standardError.write(Data(String(cString: text).utf8))
        }, nil)
    }()
}
