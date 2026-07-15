import XCTest

final class VoiceCoordinatorTests: XCTestCase {
    private final class FakeLink: VoiceLink {
        var sent: [VoiceCommand] = []
        func send(_ command: VoiceCommand) { sent.append(command) }
    }
    private final class FakeInjector: PromptInjecting {
        var prompts: [String] = []
        func sendPrompt(_ text: String) { prompts.append(text) }
    }
    private final class FakeSpeaking: SpeakingSource {
        var isSpeaking = false
    }
    private final class FakeStopper: SpeechStopping {
        var stops = 0
        func stopSpeaking(now: TimeInterval) { stops += 1 }
    }

    private func make(bargeIn: Bool = true, followUp: TimeInterval = 8)
        -> (VoiceCoordinator, FakeLink, FakeInjector, FakeSpeaking, FakeStopper) {
        let link = FakeLink(), inj = FakeInjector(), spk = FakeSpeaking(), stop = FakeStopper()
        let c = VoiceCoordinator(
            controller: ConversationController(followUpWindowSeconds: followUp,
                                               listenWindowSeconds: 10, replyTimeoutSeconds: 30),
            link: link, injector: inj, speaking: spk, stopper: stop,
            bargeInEnabled: { bargeIn })
        return (c, link, inj, spk, stop)
    }

    /// Drives the coordinator into the `.speaking` reply state and returns the fakes.
    private func intoSpeaking(bargeIn: Bool = true)
        -> (VoiceCoordinator, FakeLink, FakeInjector, FakeSpeaking, FakeStopper) {
        let (c, link, inj, spk, stop) = make(bargeIn: bargeIn)
        c.handle(.wake, now: 0)                 // -> listening, mode(.listen)
        c.handle(.heard(text: "question"), now: 1)   // -> awaitingReply, inject
        spk.isSpeaking = true
        c.tick(now: 2)                          // reply started -> speaking, mode(.speaking)
        link.sent.removeAll(); inj.prompts.removeAll(); stop.stops = 0
        return (c, link, inj, spk, stop)
    }

    func testWakeOpensListen() {
        let (c, link, _, _, _) = make()
        c.handle(.wake, now: 0)
        XCTAssertEqual(link.sent, [.mode(.listen)])
    }

    func testHeardInjectsAfterWake() {
        let (c, _, inj, _, _) = make()
        c.handle(.wake, now: 0)
        c.handle(.heard(text: "what's the weather"), now: 1)
        XCTAssertEqual(inj.prompts, ["what's the weather"])
    }

    func testReplyStartedThenFinishedDrivesModes() {
        let (c, link, _, spk, _) = make()
        c.handle(.wake, now: 0)
        c.handle(.heard(text: "q"), now: 1)
        spk.isSpeaking = true
        c.tick(now: 2)
        XCTAssertTrue(link.sent.contains(.mode(.speaking)))
        spk.isSpeaking = false
        c.tick(now: 3)
        XCTAssertTrue(link.sent.contains(.mode(.followUp)))
    }

    func testBargeInVadOnsetWhileSpeaking() {
        let (c, link, _, spk, stop) = intoSpeaking()
        spk.isSpeaking = true
        c.handle(.vad(speaking: true), now: 5)
        XCTAssertEqual(stop.stops, 1)
        XCTAssertTrue(link.sent.contains(.mode(.listen)))
    }

    func testBargeInDisabledIgnoresVadOnset() {
        let (c, _, _, spk, stop) = intoSpeaking(bargeIn: false)
        spk.isSpeaking = true
        c.handle(.vad(speaking: true), now: 5)
        XCTAssertEqual(stop.stops, 0)
    }

    func testHeardWhileSpeakingSafetyNet() {
        let (c, _, inj, _, stop) = intoSpeaking()
        c.handle(.heard(text: "actually stop"), now: 5)
        XCTAssertEqual(stop.stops, 1)
        XCTAssertEqual(inj.prompts, ["actually stop"])
    }


    func testHeardWhileSpeakingIgnoredWhenBargeInDisabled() {
        // Mirrors testHeardWhileSpeakingSafetyNet with bargeIn: false — the
        // decided "never interrupt" mode: a heard-while-speaking transcript must
        // be dropped entirely, not just its `.inject`.
        let (c, link, inj, spk, stop) = intoSpeaking(bargeIn: false)
        c.handle(.heard(text: "actually stop"), now: 5)
        XCTAssertEqual(stop.stops, 0, "must not stop speech when barge-in is disabled")
        XCTAssertTrue(inj.prompts.isEmpty, "must not inject a heard-while-speaking transcript")
        XCTAssertTrue(link.sent.isEmpty)

        // Controller state must still be .speaking — not advanced to
        // .awaitingReply by the dropped `heard` — so the normal
        // speaking -> not-speaking transition still fires replyFinished.
        spk.isSpeaking = false
        c.tick(now: 6)
        XCTAssertTrue(link.sent.contains(.mode(.followUp)),
                      "controller state must remain .speaking so replyFinished still fires normally")
    }

    func testVadOnsetIgnoredWhenNotSpeaking() {
        let (c, link, _, spk, stop) = make()
        spk.isSpeaking = false
        c.handle(.vad(speaking: true), now: 1)
        XCTAssertEqual(stop.stops, 0)
        XCTAssertTrue(link.sent.isEmpty)
    }

    func testNonVoiceReplyIsNoOp() {
        // Face speaks with no active conversation (e.g. a WhatsApp message surfaces).
        let (c, link, _, spk, _) = make()
        spk.isSpeaking = true
        c.tick(now: 1)                          // replyStarted guards non-idle -> []
        spk.isSpeaking = false
        c.tick(now: 2)                          // replyFinished guards .speaking -> []
        XCTAssertTrue(link.sent.isEmpty)
    }

    func testFollowUpTimesOutToArmed() {
        let (c, link, _, spk, _) = make(followUp: 8)
        c.handle(.wake, now: 0)
        c.handle(.heard(text: "q"), now: 1)
        spk.isSpeaking = true; c.tick(now: 2)   // speaking
        spk.isSpeaking = false; c.tick(now: 3)  // followUp opens at 3
        link.sent.removeAll()
        c.tick(now: 3 + 8 + 0.1)                // window elapsed
        XCTAssertEqual(link.sent, [.mode(.armed)])
    }

    func testSetFollowUpWindowAppliesLive() {
        let (c, link, _, spk, _) = make(followUp: 8)
        c.setFollowUpWindow(2)
        c.handle(.wake, now: 0)
        c.handle(.heard(text: "q"), now: 1)
        spk.isSpeaking = true; c.tick(now: 2)
        spk.isSpeaking = false; c.tick(now: 3)  // followUp opens at 3
        link.sent.removeAll()
        c.tick(now: 3 + 2 + 0.1)                // 2s window -> armed
        XCTAssertEqual(link.sent, [.mode(.armed)])
    }

    func testErrorEventDoesNotWedge() {
        let (c, link, inj, _, stop) = make()
        c.handle(.error(message: "whisper failed"), now: 0)
        XCTAssertTrue(link.sent.isEmpty)
        XCTAssertTrue(inj.prompts.isEmpty)
        XCTAssertEqual(stop.stops, 0)
    }
}
