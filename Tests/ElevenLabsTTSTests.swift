import XCTest

final class ElevenLabsTTSTests: XCTestCase {
    func testMakeRequestShape() throws {
        var cfg = SpeechConfig()
        cfg.apiKey = "key"
        cfg.voiceId = "voice123"
        cfg.languageCode = "it"
        cfg.speed = 1.2
        let req = ElevenLabsTTS.makeRequest(text: "Ciao.", previousRequestIDs: ["r1", "r2"], config: cfg)
        XCTAssertEqual(req.url?.absoluteString,
            "https://api.elevenlabs.io/v1/text-to-speech/voice123/with-timestamps?output_format=pcm_24000")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "xi-api-key"), "key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "Ciao.")
        XCTAssertEqual(body["model_id"] as? String, "eleven_flash_v2_5")
        XCTAssertEqual(body["language_code"] as? String, "it")
        XCTAssertEqual(body["previous_request_ids"] as? [String], ["r1", "r2"])
        let vs = try XCTUnwrap(body["voice_settings"] as? [String: Any])
        XCTAssertEqual(vs["speed"] as? Double, 1.2)
    }

    func testMakeRequestOmitsOptionalFields() throws {
        var cfg = SpeechConfig()
        cfg.apiKey = "key"
        cfg.voiceId = "v"
        let req = ElevenLabsTTS.makeRequest(text: "Hi.", previousRequestIDs: [], config: cfg)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertNil(body["language_code"])
        XCTAssertNil(body["previous_request_ids"])
    }

    func testParseResponseExtractsWordsAndPCM() throws {
        let pcm = Data([0x01, 0x00, 0x02, 0x00])
        let json = """
        {"audio_base64": "\(pcm.base64EncodedString())",
         "alignment": {"characters": ["H", "i"],
                       "character_start_times_seconds": [0.0, 0.1],
                       "character_end_times_seconds": [0.1, 0.2]}}
        """
        let audio = try ElevenLabsTTS.parseResponse(Data(json.utf8), requestID: "rid")
        XCTAssertFalse(audio.envelope.isEmpty)   // envelope computed from the PCM
        XCTAssertEqual(audio.envelopeRate, 60)
        XCTAssertEqual(audio.requestID, "rid")
        XCTAssertEqual(audio.pcm, pcm)
        XCTAssertEqual(audio.words, [WordTiming(text: "Hi", start: 0.0, end: 0.2)])
        XCTAssertEqual(audio.sampleRate, 24_000)
    }

    func testParseResponseRejectsMissingAlignment() {
        let json = #"{"audio_base64": "AAA="}"#
        XCTAssertThrowsError(try ElevenLabsTTS.parseResponse(Data(json.utf8), requestID: nil as String?))
    }
}
