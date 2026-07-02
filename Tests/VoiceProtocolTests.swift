import XCTest

final class VoiceProtocolTests: XCTestCase {
    func testEventRoundTrips() {
        let events: [VoiceEvent] = [.ready(version: 1), .wake, .listening,
                                    .vad(speaking: true), .vad(speaking: false),
                                    .heard(text: "what's the weather"), .error(message: "mic denied")]
        for e in events {
            XCTAssertEqual(VoiceProtocol.decodeEvent(VoiceProtocol.encode(e)), e)
        }
    }
    func testCommandRoundTrips() {
        for c in [VoiceCommand.mode(.armed), .mode(.listen), .mode(.speaking), .mode(.followUp), .stop] {
            XCTAssertEqual(VoiceProtocol.decodeCommand(VoiceProtocol.encode(c)), c)
        }
    }
    func testWireFormatIsStable() {
        // Pin the wire format so both sides can evolve independently.
        let d = VoiceProtocol.encode(VoiceEvent.heard(text: "hi"))
        let obj = try! JSONSerialization.jsonObject(with: d) as! [String: Any]
        XCTAssertEqual(obj["event"] as? String, "heard")
        XCTAssertEqual(obj["text"] as? String, "hi")
        let c = VoiceProtocol.encode(VoiceCommand.mode(.followUp))
        let cobj = try! JSONSerialization.jsonObject(with: c) as! [String: Any]
        XCTAssertEqual(cobj["cmd"] as? String, "mode")
        XCTAssertEqual(cobj["mode"] as? String, "followup")
    }
    func testGarbageDecodesToNil() {
        XCTAssertNil(VoiceProtocol.decodeEvent(Data("junk".utf8)))
        XCTAssertNil(VoiceProtocol.decodeCommand(Data("{\"cmd\":\"nope\"}".utf8)))
    }
}
