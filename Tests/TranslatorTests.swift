import XCTest

final class TranslatorTests: XCTestCase {
    // MARK: - helpers

    private func translate(_ json: String) -> [AgentEvent] {
        OpenClawTranslator.translate(Data(json.utf8))
    }

    /// Stateful helper: thread-unsafe, fine for serial test use.
    private func translate(_ json: String, context: inout TranslationContext) -> [AgentEvent] {
        OpenClawTranslator.translate(Data(json.utf8), context: &context)
    }

    // MARK: - Existing agent-stream tests (unchanged)

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

    // MARK: - sessions.changed tests

    // Case 1: changed(start) produces runStarted and records context entry.
    func testSessionsChangedStartProducesRunStarted() {
        var ctx = TranslationContext()
        let json = #"{"type":"event","event":"sessions.changed","payload":{"sessionKey":"agent:main:whatsapp:direct:+353838112174","phase":"start","runId":"b1ee0e1a-8a95-4b51-8f89-16a2b06a4b71","ts":1780596217011,"session":{"key":"agent:main:whatsapp:direct:+353838112174","origin":{"surface":"whatsapp"}}}}"#
        let events = translate(json, context: &ctx)
        XCTAssertEqual(events, [.runStarted(
            run: "b1ee0e1a-8a95-4b51-8f89-16a2b06a4b71",
            session: "agent:main:whatsapp:direct:+353838112174")])
        XCTAssertEqual(
            ctx.activeChannelRuns["agent:main:whatsapp:direct:+353838112174"],
            "b1ee0e1a-8a95-4b51-8f89-16a2b06a4b71")
    }

    // Case 2: changed(end) produces runEnded and removes context entry.
    func testSessionsChangedEndProducesRunEndedAndClearsMap() {
        var ctx = TranslationContext()
        ctx.activeChannelRuns["agent:main:whatsapp:direct:+353838112174"] =
            "b1ee0e1a-8a95-4b51-8f89-16a2b06a4b71"
        let json = #"{"type":"event","event":"sessions.changed","payload":{"sessionKey":"agent:main:whatsapp:direct:+353838112174","phase":"end","runId":"b1ee0e1a-8a95-4b51-8f89-16a2b06a4b71","ts":1780596218854,"session":{"key":"agent:main:whatsapp:direct:+353838112174"}}}"#
        let events = translate(json, context: &ctx)
        XCTAssertEqual(events, [.runEnded(
            run: "b1ee0e1a-8a95-4b51-8f89-16a2b06a4b71",
            session: "agent:main:whatsapp:direct:+353838112174")])
        XCTAssertNil(ctx.activeChannelRuns["agent:main:whatsapp:direct:+353838112174"])
    }

    // Case 3: Full sequence start→user→assistant→end yields correct event sequence.
    func testFullChannelSessionSequence() {
        var ctx = TranslationContext()
        let sessionKey = "agent:main:whatsapp:direct:+353838112174"
        let runId = "b1ee0e1a-8a95-4b51-8f89-16a2b06a4b71"

        let changedStart = #"{"type":"event","event":"sessions.changed","payload":{"sessionKey":"agent:main:whatsapp:direct:+353838112174","phase":"start","runId":"b1ee0e1a-8a95-4b51-8f89-16a2b06a4b71","ts":1780596217011,"session":{"key":"agent:main:whatsapp:direct:+353838112174","origin":{"surface":"whatsapp"}}}}"#
        let userMsg = #"{"type":"event","event":"session.message","payload":{"sessionKey":"agent:main:whatsapp:direct:+353838112174","agentId":"main","messageId":"b45d4428","messageSeq":90,"message":{"role":"user","content":"Ok one more test, hopefully the last. Answer please","timestamp":1780596216902}}}"#
        let assistantMsg = #"{"type":"event","event":"session.message","payload":{"sessionKey":"agent:main:whatsapp:direct:+353838112174","agentId":"main","messageId":"9fe65f2e","messageSeq":91,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"Giovanni is doing another test."},{"type":"text","text":"Last test, confirmed. Answering loud and clear. ✅"}],"timestamp":1780596217015}}}"#
        let changedEnd = #"{"type":"event","event":"sessions.changed","payload":{"sessionKey":"agent:main:whatsapp:direct:+353838112174","phase":"end","runId":"b1ee0e1a-8a95-4b51-8f89-16a2b06a4b71","ts":1780596218854,"session":{"key":"agent:main:whatsapp:direct:+353838112174"}}}"#

        XCTAssertEqual(translate(changedStart, context: &ctx),
                       [.runStarted(run: runId, session: sessionKey)])
        XCTAssertEqual(translate(userMsg, context: &ctx), [])
        XCTAssertEqual(translate(assistantMsg, context: &ctx),
                       [.textDelta(run: runId, session: sessionKey,
                                   text: "Last test, confirmed. Answering loud and clear. ✅")])
        XCTAssertEqual(translate(changedEnd, context: &ctx),
                       [.runEnded(run: runId, session: sessionKey)])
    }

    // Case 4: Assistant message with no active run synthesises runStarted+textDelta+runEnded keyed by messageId.
    func testAssistantMessageWithNoActiveRunSynthesisesRun() {
        var ctx = TranslationContext()
        let sessionKey = "agent:main:whatsapp:direct:+353838112174"
        let json = #"{"type":"event","event":"session.message","payload":{"sessionKey":"agent:main:whatsapp:direct:+353838112174","agentId":"main","messageId":"9fe65f2e","messageSeq":91,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"Giovanni is doing another test."},{"type":"text","text":"Last test, confirmed. Answering loud and clear. ✅"}],"timestamp":1780596217015}}}"#
        let events = translate(json, context: &ctx)
        XCTAssertEqual(events, [
            .runStarted(run: "9fe65f2e", session: sessionKey),
            .textDelta(run: "9fe65f2e", session: sessionKey,
                       text: "Last test, confirmed. Answering loud and clear. ✅"),
            .runEnded(run: "9fe65f2e", session: sessionKey),
        ])
    }

    // Case 5: User message always returns [].
    func testUserMessageAlwaysIgnored() {
        var ctx = TranslationContext()
        let json = #"{"type":"event","event":"session.message","payload":{"sessionKey":"agent:main:whatsapp:direct:+353838112174","agentId":"main","messageId":"b45d4428","messageSeq":90,"message":{"role":"user","content":"Ok one more test, hopefully the last. Answer please","timestamp":1780596216902}}}"#
        XCTAssertEqual(translate(json, context: &ctx), [])
    }

    // Case 6: Both event types with sessionKey == mainSessionKey are ignored.
    func testMainSessionKeyIgnoredForChannelEvents() {
        var ctx = TranslationContext()
        // main session changed
        let changedMain = #"{"type":"event","event":"sessions.changed","payload":{"sessionKey":"agent:main:main","phase":"start","runId":"r-main","ts":1,"session":{}}}"#
        XCTAssertEqual(translate(changedMain, context: &ctx), [])
        // main session message
        let msgMain = #"{"type":"event","event":"session.message","payload":{"sessionKey":"agent:main:main","agentId":"main","messageId":"msg1","messageSeq":1,"message":{"role":"assistant","content":[{"type":"text","text":"hello"}],"timestamp":1}}}"#
        XCTAssertEqual(translate(msgMain, context: &ctx), [])
    }

    // Case 7: Assistant message with only a thinking block → [].
    func testAssistantOnlyThinkingBlockProducesEmpty() {
        var ctx = TranslationContext()
        let json = #"{"type":"event","event":"session.message","payload":{"sessionKey":"agent:main:whatsapp:direct:+353838112174","agentId":"main","messageId":"abc","messageSeq":1,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}],"timestamp":1}}}"#
        XCTAssertEqual(translate(json, context: &ctx), [])
    }

    // Case 8: changed(start) with missing/empty runId → [].
    func testSessionsChangedMissingRunIdDropped() {
        var ctx = TranslationContext()
        let missing = #"{"type":"event","event":"sessions.changed","payload":{"sessionKey":"agent:main:whatsapp:direct:+353838112174","phase":"start","ts":1,"session":{}}}"#
        let empty = #"{"type":"event","event":"sessions.changed","payload":{"sessionKey":"agent:main:whatsapp:direct:+353838112174","phase":"start","runId":"","ts":1,"session":{}}}"#
        XCTAssertEqual(translate(missing, context: &ctx), [])
        XCTAssertEqual(translate(empty, context: &ctx), [])
    }

    // Case 9 is covered — all existing tests above still use the single-arg translate(), unchanged.

    // Case 10: Multiple text blocks join with "\n".
    func testMultipleTextBlocksJoinedWithNewline() {
        var ctx = TranslationContext()
        let sessionKey = "agent:main:whatsapp:direct:+353838112174"
        ctx.activeChannelRuns[sessionKey] = "run-multi"
        let json = #"{"type":"event","event":"session.message","payload":{"sessionKey":"agent:main:whatsapp:direct:+353838112174","agentId":"main","messageId":"abc","messageSeq":1,"message":{"role":"assistant","content":[{"type":"text","text":"First"},{"type":"thinking","thinking":"..."},{"type":"text","text":"Second"}],"timestamp":1}}}"#
        let events = translate(json, context: &ctx)
        XCTAssertEqual(events, [.textDelta(run: "run-multi", session: sessionKey, text: "First\nSecond")])
    }
}
