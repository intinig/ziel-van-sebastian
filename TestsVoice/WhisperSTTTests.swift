import XCTest

final class WhisperSTTTests: XCTestCase {
    private var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ziel van Sebastian/models")
    }
    private func fixtureSamples() throws -> [Float] {
        let url = Bundle(for: Self.self).url(forResource: "sebastian-weather", withExtension: "wav")!
        let wav = try Data(contentsOf: url)
        // Fixture must be a bare 44-byte-header WAV. Regenerate ONLY with --no-filler:
        //   say -o /tmp/f.aiff "Sebastian, what's the weather today?" && afconvert -f WAVE -d LEI16@16000 -c 1 --no-filler /tmp/f.aiff TestsVoice/Fixtures/sebastian-weather.wav
        // (without --no-filler, afconvert may insert a FLLR chunk before "data", silently mis-parsing into garbage floats)
        let pcm16 = wav.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return pcm16.map { Float($0) / 32768.0 }
    }

    func testTranscribesFixture() throws {
        let model = modelsDir.appendingPathComponent("ggml-base.en.bin").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model), "run scripts/fetch-voice-models.sh")
        let stt = try WhisperSTT(modelPath: model)
        let text = stt.transcribe(try fixtureSamples()).lowercased()
        XCTAssertTrue(text.contains("sebastian"), "got: \(text)")
        XCTAssertTrue(text.contains("weather"), "got: \(text)")
    }

    func testTranscribesQuietAudio() throws {
        // Distant/soft speech reaches the mic at a fraction of full scale
        // (appliance PowerConf across the room). Transcription must still work.
        let model = modelsDir.appendingPathComponent("ggml-base.en.bin").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model), "run scripts/fetch-voice-models.sh")
        let stt = try WhisperSTT(modelPath: model)
        let quiet = try fixtureSamples().map { $0 * 0.03 }
        let text = stt.transcribe(quiet).lowercased()
        XCTAssertTrue(text.contains("sebastian"), "got: \(text)")
        XCTAssertTrue(text.contains("weather"), "got: \(text)")
    }

    func testLanguagesAllowlistClampsToEnglish() throws {
        // Multilingual model, so there's an actual whisper_lang_auto_detect to
        // clamp; on an English-only (*.en) model the production-code guard
        // (whisper_is_multilingual == false) skips the clamp entirely and this
        // would just re-exercise testTranscribesFixture instead of proving the
        // detection path itself.
        let model = modelsDir.appendingPathComponent("ggml-base.bin").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model), "run scripts/fetch-voice-models.sh (multilingual ggml-base.bin)")
        let stt = try WhisperSTT(modelPath: model, languages: ["it", "en"])
        let text = stt.transcribe(try fixtureSamples()).lowercased()
        XCTAssertTrue(text.contains("sebastian"), "got: \(text)")
        XCTAssertTrue(text.contains("weather"), "got: \(text)")
    }

    func testLanguagesAllowlistUnknownCodeFallsBackToAuto() throws {
        // "xx" isn't a whisper language code; with no valid id left in the
        // allowlist, transcription must fall back to unclamped auto-detect
        // rather than crash or leave params.language dangling.
        let model = modelsDir.appendingPathComponent("ggml-base.bin").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model), "run scripts/fetch-voice-models.sh (multilingual ggml-base.bin)")
        let stt = try WhisperSTT(modelPath: model, languages: ["xx"])
        let text = stt.transcribe(try fixtureSamples()).lowercased()
        XCTAssertTrue(text.contains("sebastian"), "got: \(text)")
        XCTAssertTrue(text.contains("weather"), "got: \(text)")
    }

    func testVADSeparatesSpeechFromSilence() throws {
        let model = modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model), "run scripts/fetch-voice-models.sh")
        let vad = try SileroVAD(modelPath: model)
        let samples = try fixtureSamples()
        // Feed real audio frames; the last prob (mid-utterance) should read as speech.
        let silence = [Float](repeating: 0, count: 512)
        var speechProb: Float = 0
        for start in stride(from: 4096, to: 12288, by: 512) {   // warms the RNN state over real audio
            speechProb = vad.speechProbability(frame512: Array(samples[start..<start + 512]))
        }
        vad.reset()
        var silenceProb: Float = 1
        for _ in 0..<8 { silenceProb = vad.speechProbability(frame512: silence) }
        XCTAssertGreaterThan(speechProb, 0.5, "speech should score high")
        XCTAssertLessThan(silenceProb, 0.2, "silence should score low")
    }
}
