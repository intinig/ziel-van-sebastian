import XCTest

final class WhisperSTTTests: XCTestCase {
    private var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ziel van Sebastian/models")
    }
    private func fixtureSamples() throws -> [Float] {
        let url = Bundle(for: Self.self).url(forResource: "sebastian-weather", withExtension: "wav")!
        let wav = try Data(contentsOf: url)
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
