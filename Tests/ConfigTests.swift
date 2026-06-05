import XCTest

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = ZielConfig()
        XCTAssertEqual(c.gateway.url, "ws://127.0.0.1:18789")
        XCTAssertEqual(c.pacing.baseMs, 280)
        XCTAssertEqual(c.behavior.dozeAfterSeconds, 600)
        // look is now a pure overlay: empty by default, values come from the theme.
        XCTAssertEqual(c.look, LookConfig())
        XCTAssertNil(c.look.theme)
        XCTAssertNil(c.look.idleTint)
        XCTAssertNil(c.look.shader)
    }

    func testPartialJSONMergesWithDefaults() throws {
        let json = #"{"gateway":{"token":"sek"},"pacing":{"baseMs":200}}"#
        let c = try ZielConfig.decode(Data(json.utf8))
        XCTAssertEqual(c.gateway.token, "sek")
        XCTAssertEqual(c.gateway.url, "ws://127.0.0.1:18789")   // default survives
        XCTAssertEqual(c.pacing.baseMs, 200)
        XCTAssertEqual(c.pacing.perCharMs, 60)                  // default survives
    }

    func testMissingFileGivesDefaults() {
        let c = ZielConfig.load(from: URL(fileURLWithPath: "/nonexistent/nope.json"))
        XCTAssertEqual(c, ZielConfig())
    }

    func testInvalidJSONGivesDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("ziel-bad-\(UUID().uuidString).json")
        try Data("not json{{{".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ZielConfig.load(from: url), ZielConfig())
    }

    func testLookOverlayDecodesOnlyPresentKeys() throws {
        let json = "{\"look\":{\"theme\":\"classic\",\"idleTint\":\"#ff0000\",\"shader\":{\"scanlineIntensity\":0.99}}}"
        let c = try ZielConfig.decode(Data(json.utf8))
        XCTAssertEqual(c.look.theme, "classic")
        XCTAssertEqual(c.look.idleTint, "#ff0000")
        XCTAssertEqual(c.look.shader?.scanlineIntensity, 0.99)
        XCTAssertNil(c.look.shader?.persistence)    // absent key stays nil
        XCTAssertNil(c.look.thinkingTint)           // absent key stays nil
    }

    func testLookOverlayResolvesAgainstTheme() throws {
        let json = "{\"look\":{\"shader\":{\"scanlineIntensity\":0.99}}}"
        let c = try ZielConfig.decode(Data(json.utf8))
        let r = try ResolvedLook.resolve(c.look)    // default theme: hello
        XCTAssertEqual(r.shader.scanlineIntensity, 0.99, accuracy: 0.0001)
        XCTAssertEqual(r.shader.persistence, 0.82, accuracy: 0.0001)  // theme survives
        XCTAssertEqual(r.idleTint, "#8a877c")                          // theme survives
    }

    func testSpeechConfigDefaults() throws {
        let cfg = try ZielConfig.decode(Data("{}".utf8))
        XCTAssertFalse(cfg.speech.enabled)
        XCTAssertEqual(cfg.speech.apiKey, "")
        XCTAssertEqual(cfg.speech.voiceId, "")
        XCTAssertEqual(cfg.speech.modelId, "eleven_flash_v2_5")
        XCTAssertNil(cfg.speech.languageCode)
        XCTAssertEqual(cfg.speech.speed, 1.0)
        XCTAssertEqual(cfg.speech.volume, 1.0)
    }

    func testSpeechConfigDecodes() throws {
        let json = """
        {"speech": {"enabled": true, "apiKey": "k", "voiceId": "v",
                    "modelId": "eleven_multilingual_v2", "languageCode": "it",
                    "speed": 1.1, "volume": 0.8}}
        """
        let cfg = try ZielConfig.decode(Data(json.utf8))
        XCTAssertTrue(cfg.speech.enabled)
        XCTAssertEqual(cfg.speech.apiKey, "k")
        XCTAssertEqual(cfg.speech.voiceId, "v")
        XCTAssertEqual(cfg.speech.modelId, "eleven_multilingual_v2")
        XCTAssertEqual(cfg.speech.languageCode, "it")
        XCTAssertEqual(cfg.speech.speed, 1.1)
        XCTAssertEqual(cfg.speech.volume, 0.8)
    }
}
