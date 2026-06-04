import XCTest

final class TranslatorTests: XCTestCase {
    private func translate(_ json: String) -> [AgentEvent] {
        OpenClawTranslator.translate(Data(json.utf8))
    }

    func testLifecycleStart() {
        let events = translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":0,"stream":"lifecycle","ts":1,"sessionKey":"main","data":{"phase":"start"}}}"#)
        XCTAssertEqual(events, [.runStarted(run: "r1", session: "main")])
    }

    func testLifecycleEndAndError() {
        XCTAssertEqual(
            translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":9,"stream":"lifecycle","ts":1,"sessionKey":"main","data":{"phase":"end"}}}"#),
            [.runEnded(run: "r1", session: "main")])
        XCTAssertEqual(
            translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":9,"stream":"lifecycle","ts":1,"sessionKey":"main","data":{"phase":"error"}}}"#),
            [.runEnded(run: "r1", session: "main")])
    }

    func testToolStartCarriesName() {
        let events = translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":2,"stream":"tool","ts":1,"sessionKey":"main","data":{"phase":"start","name":"read","toolCallId":"t1","args":{}}}}"#)
        XCTAssertEqual(events, [.toolStarted(run: "r1", session: "main", tool: "read")])
    }

    func testToolResultIgnored() {
        let events = translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":3,"stream":"tool","ts":1,"data":{"phase":"result","name":"read","toolCallId":"t1","isError":false,"result":"…"}}}"#)
        XCTAssertEqual(events, [])
    }

    func testAssistantDelta() {
        let events = translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":4,"stream":"assistant","ts":1,"sessionKey":"main","data":{"delta":"Hello "}}}"#)
        XCTAssertEqual(events, [.textDelta(run: "r1", session: "main", text: "Hello ")])
    }

    func testHeartbeatDropped() {
        let events = translate(#"{"type":"event","event":"agent","payload":{"runId":"hb","seq":0,"stream":"lifecycle","ts":1,"isHeartbeat":true,"data":{"phase":"start"}}}"#)
        XCTAssertEqual(events, [])
    }

    func testMissingSessionKeyFallsBackToRunId() {
        let events = translate(#"{"type":"event","event":"agent","payload":{"runId":"r9","seq":0,"stream":"lifecycle","ts":1,"data":{"phase":"start"}}}"#)
        XCTAssertEqual(events, [.runStarted(run: "r9", session: "r9")])
    }

    func testOtherStreamsAndEventsIgnored() {
        XCTAssertEqual(translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":5,"stream":"thinking","ts":1,"data":{"delta":"hmm"}}}"#), [])
        XCTAssertEqual(translate(#"{"type":"event","event":"chat","payload":{"runId":"r1","sessionKey":"main","seq":1,"state":"delta","deltaText":"x"}}"#), [])
        XCTAssertEqual(translate(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"n"}}"#), [])
        XCTAssertEqual(translate(#"{"type":"res","id":"connect-1","ok":true,"payload":{}}"#), [])
    }

    func testGarbageNeverThrows() {
        XCTAssertEqual(translate("not json at all {{{"), [])
        XCTAssertEqual(translate(#"{"type":"event","event":"agent","payload":{"stream":"assistant"}}"#), [])
    }

    func testEmptyRunIdDropped() {
        XCTAssertEqual(translate(#"{"type":"event","event":"agent","payload":{"runId":"","seq":0,"stream":"lifecycle","ts":1,"data":{"phase":"start"}}}"#), [])
    }

    func testEmptySessionKeyFallsBackToRunId() {
        XCTAssertEqual(
            translate(#"{"type":"event","event":"agent","payload":{"runId":"r3","seq":0,"stream":"lifecycle","ts":1,"sessionKey":"","data":{"phase":"start"}}}"#),
            [.runStarted(run: "r3", session: "r3")])
    }
}
