import XCTest

final class ConversationControllerTests: XCTestCase {
    private func make() -> ConversationController {
        ConversationController(followUpWindowSeconds: 8, listenWindowSeconds: 10, replyTimeoutSeconds: 30)
    }

    func testWakeFromIdleStartsListening() {
        let c = make()
        XCTAssertEqual(c.wake(now: 0), [.setWakeMode(.listen)])
        XCTAssertEqual(c.state, .listening)
    }

    func testWakeIgnoredWhenNotIdle() {
        let c = make(); _ = c.wake(now: 0)
        XCTAssertEqual(c.wake(now: 1), [])   // already listening
    }

    func testHeardInListeningInjectsAndAwaitsReply() {
        let c = make(); _ = c.wake(now: 0)
        XCTAssertEqual(c.heard(text: "  what's the weather ", now: 1), [.inject("what's the weather")])
        XCTAssertEqual(c.state, .awaitingReply)
    }

    func testStraySpeechInIdleIgnored() {
        let c = make()
        XCTAssertEqual(c.heard(text: "random chatter", now: 1), [])
        XCTAssertEqual(c.state, .idle)
    }

    func testReplyLifecycleOpensFollowUp() {
        let c = make(); _ = c.wake(now: 0); _ = c.heard(text: "hi", now: 1)
        XCTAssertEqual(c.replyStarted(now: 2), [.setWakeMode(.speaking)])
        XCTAssertEqual(c.state, .speaking)
        XCTAssertEqual(c.replyFinished(now: 5), [.setWakeMode(.followUp)])
        XCTAssertEqual(c.state, .followUp)
    }

    func testFollowUpAcceptsSpeechWithoutWakeWord() {
        let c = make(); _ = c.wake(now: 0); _ = c.heard(text: "hi", now: 1)
        _ = c.replyStarted(now: 2); _ = c.replyFinished(now: 5)
        XCTAssertEqual(c.heard(text: "and tomorrow?", now: 6), [.inject("and tomorrow?")])
        XCTAssertEqual(c.state, .awaitingReply)
    }

    func testFollowUpTimesOutToIdle() {
        let c = make(); _ = c.wake(now: 0); _ = c.heard(text: "hi", now: 1)
        _ = c.replyStarted(now: 2); _ = c.replyFinished(now: 5)
        XCTAssertEqual(c.tick(now: 12), [])              // 12-5 = 7 < 8, still open
        XCTAssertEqual(c.tick(now: 13.1), [.setWakeMode(.armed)])  // 13.1-5 = 8.1 >= 8
        XCTAssertEqual(c.state, .idle)
    }

    func testBargeInStopsSpeakingAndRelistens() {
        let c = make(); _ = c.wake(now: 0); _ = c.heard(text: "hi", now: 1)
        _ = c.replyStarted(now: 2)
        XCTAssertEqual(c.bargeInDetected(now: 3), [.stopSpeaking, .setWakeMode(.listen)])
        XCTAssertEqual(c.state, .listening)
        XCTAssertEqual(c.heard(text: "actually never mind", now: 4), [.inject("actually never mind")])
    }

    func testBargeInIgnoredWhenNotSpeaking() {
        let c = make(); _ = c.wake(now: 0)
        XCTAssertEqual(c.bargeInDetected(now: 1), [])
    }

    func testListenTimesOutIfNoSpeech() {
        let c = make(); _ = c.wake(now: 0)
        XCTAssertEqual(c.tick(now: 11), [.setWakeMode(.armed)])  // 11 >= 10
        XCTAssertEqual(c.state, .idle)
    }

    func testAwaitingReplyTimesOutIfAgentSilent() {
        let c = make(); _ = c.wake(now: 0); _ = c.heard(text: "hi", now: 1)
        XCTAssertEqual(c.tick(now: 32), [.setWakeMode(.armed)])  // 32-1 = 31 >= 30
        XCTAssertEqual(c.state, .idle)
    }
}
