import XCTest

final class DirectorSpeechTests: XCTestCase {
    private func makeSpeechDirector() -> Director {
        var cfg = ZielConfig()
        cfg.speech.enabled = true
        var look = LookConfig()
        look.theme = "classic"
        return Director(config: cfg, look: try! ResolvedLook.resolve(look))
    }

    func testSentencesQueueAsRequestsNotPacedWords() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "Hello world. More"), now: 1)
        XCTAssertEqual(d.takeSpeechRequests().map(\.text), ["Hello world."])
        XCTAssertEqual(d.takeSpeechRequests(), [])          // outbox drains
        let s = d.tick(now: 2)                              // waking (0.8s) done
        XCTAssertEqual(s.phase, .thinking)                  // NOT speaking: no audio yet
        XCTAssertNil(s.word)
    }

    func testRunEndFlushesTrailingFragment() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "Done. And then"), now: 1)
        _ = d.takeSpeechRequests()
        d.handle(.runEnded(run: "r1", session: "main"), now: 1.5)
        XCTAssertEqual(d.takeSpeechRequests().map(\.text), ["And then"])
    }

    func testStaysThinkingWhileAwaitingTTSAfterRunEnded() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "Hi. "), now: 1)
        d.handle(.runEnded(run: "r1", session: "main"), now: 1.1)
        _ = d.takeSpeechRequests()
        // Long after settling would normally happen, speech is still in flight:
        XCTAssertEqual(d.tick(now: 10).phase, .thinking)
    }

    func testRequestIDsAreSequentialAcrossSentences() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "One. Two. Three. "), now: 1)
        XCTAssertEqual(d.takeSpeechRequests().map(\.id), [0, 1, 2])
    }

    func testConnectionDownClearsSpeechState() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "Hello. "), now: 1)
        d.handle(.connectionDown(auth: false), now: 2)
        XCTAssertEqual(d.takeSpeechRequests(), [])
        d.handle(.connectionUp, now: 3)
        XCTAssertEqual(d.tick(now: 4).phase, .idle)         // not stuck "busy"
    }
}
