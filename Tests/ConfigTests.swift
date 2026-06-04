import XCTest

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = ZielConfig()
        XCTAssertEqual(c.gateway.url, "ws://127.0.0.1:18789")
        XCTAssertEqual(c.pacing.baseMs, 280)
        XCTAssertEqual(c.look.idleTint, "#41ff6a")
        XCTAssertEqual(c.behavior.dozeAfterSeconds, 600)
        XCTAssertEqual(c.look.shader.persistence, 0.82, accuracy: 0.001)
        XCTAssertEqual(c.look.shader.scanlinePitch, 3, accuracy: 0.001)
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

    func testNestedShaderPartialMerge() throws {
        let json = #"{"look":{"shader":{"scanlineIntensity":0.99}}}"#
        let c = try ZielConfig.decode(Data(json.utf8))
        XCTAssertEqual(c.look.shader.scanlineIntensity, 0.99)
        XCTAssertEqual(c.look.shader.persistence, 0.82, accuracy: 0.001)  // default survives
        XCTAssertEqual(c.look.idleTint, "#41ff6a")  // outer default survives too
    }
}
