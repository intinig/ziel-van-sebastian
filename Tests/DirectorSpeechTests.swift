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

    func testSpeechStartedDrivesTimedWords() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "Hi there. "), now: 1)
        d.handle(.runEnded(run: "r1", session: "main"), now: 1.1)
        let req = d.takeSpeechRequests()[0]
        XCTAssertEqual(d.tick(now: 2).phase, .thinking)
        d.speechStarted(id: req.id, words: [
            WordTiming(text: "Hi", start: 0.0, end: 0.3),
            WordTiming(text: "there.", start: 0.4, end: 0.9),
        ], now: 2.5)
        XCTAssertEqual(d.tick(now: 2.55).phase, .speaking)
        XCTAssertEqual(d.tick(now: 2.6).word, "Hi")          // 0.1s into audio
        XCTAssertEqual(d.tick(now: 3.0).word, "there.")      // 0.5s into audio
        XCTAssertEqual(d.tick(now: 3.6).word, "there.")      // past end: hold for audio tail
        d.speechFinished(id: req.id, now: 3.7)
        XCTAssertEqual(d.tick(now: 3.8).phase, .settling)    // run over, queue empty
    }

    func testWordAgeTracksTimelineWordStart() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "Go now. "), now: 1)
        let req = d.takeSpeechRequests()[0]
        _ = d.tick(now: 2)
        d.speechStarted(id: req.id, words: [
            WordTiming(text: "Go", start: 0.0, end: 0.2),
            WordTiming(text: "now.", start: 0.3, end: 0.6),
        ], now: 2.0)
        let s = d.tick(now: 2.4)                             // "now." started at 2.3
        XCTAssertEqual(s.word, "now.")
        XCTAssertEqual(s.wordAge, 0.1, accuracy: 0.0001)
    }

    func testFailedSentenceFallsBackToPacedWords() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "Hello world. "), now: 1)
        d.handle(.runEnded(run: "r1", session: "main"), now: 1.1)
        let req = d.takeSpeechRequests()[0]
        _ = d.tick(now: 2)
        d.speechFailed(id: req.id, now: 2.5)
        let s = d.tick(now: 2.6)
        XCTAssertEqual(s.phase, .speaking)
        XCTAssertEqual(s.word, "Hello")                      // paced fallback
        XCTAssertEqual(d.tick(now: 2.9).word, "world.")      // base hold 280ms
        XCTAssertEqual(d.tick(now: 4.5).phase, .settling)    // drained
    }

    func testFailedHeadDisplaysBeforeNextSpokenSentence() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "One. Two. "), now: 1)
        d.handle(.runEnded(run: "r1", session: "main"), now: 1.1)
        let reqs = d.takeSpeechRequests()
        _ = d.tick(now: 2)
        d.speechFailed(id: reqs[0].id, now: 3)
        d.speechStarted(id: reqs[1].id, words: [
            WordTiming(text: "Two.", start: 0.0, end: 5.0),
        ], now: 3)
        XCTAssertEqual(d.tick(now: 3.1).word, "One.")        // fallback first, in order
        XCTAssertEqual(d.tick(now: 4.0).word, "Two.")        // then joins the live timeline
        d.speechFinished(id: reqs[1].id, now: 8)
        XCTAssertEqual(d.tick(now: 8.2).phase, .settling)
    }

    func testHoldsLastWordBetweenSentences() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "One. Two. "), now: 1)
        let reqs = d.takeSpeechRequests()
        _ = d.tick(now: 2)
        d.speechStarted(id: reqs[0].id, words: [WordTiming(text: "One.", start: 0, end: 0.4)], now: 2)
        XCTAssertEqual(d.tick(now: 2.2).word, "One.")
        d.speechFinished(id: reqs[0].id, now: 2.5)
        // Sentence two still being synthesized: hold the last word, stay speaking.
        let s = d.tick(now: 2.6)
        XCTAssertEqual(s.phase, .speaking)
        XCTAssertEqual(s.word, "One.")
    }

    func testSpeechDisabledIgnoresCallbacks() {
        var look = LookConfig()
        look.theme = "classic"
        let d = Director(config: ZielConfig(), look: try! ResolvedLook.resolve(look))
        d.handle(.connectionUp, now: 0)
        d.speechStarted(id: 0, words: [WordTiming(text: "x", start: 0, end: 1)], now: 1)
        d.speechFinished(id: 0, now: 2)
        d.speechFailed(id: 0, now: 3)
        XCTAssertEqual(d.tick(now: 4).phase, .idle)          // no crash, no effect
    }

    func testPendingRunAdoptedThroughChunkerWhenSpeechOn() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        // r1 focused (text routes first), r2 accumulates pending
        d.handle(.textDelta(run: "r1", session: "main", text: "First. "), now: 1)
        d.handle(.textDelta(run: "r2", session: "main", text: "Second reply. "), now: 1.1)
        d.handle(.runEnded(run: "r1", session: "main"), now: 1.2)
        d.handle(.runEnded(run: "r2", session: "main"), now: 1.3)
        XCTAssertEqual(d.takeSpeechRequests().map(\.text), ["First."])
        // r1's sentence fails → displays via pacer, drains, r1 evicted,
        // r2 adopted through a fresh chunker.
        d.speechFailed(id: 0, now: 2)
        var saw = Set<String>()
        for t in stride(from: 2.0, through: 12.0, by: 0.1) {
            _ = d.tick(now: t)
            saw.formUnion(d.takeSpeechRequests().map(\.text))
        }
        XCTAssertTrue(saw.contains("Second reply."))
    }

    func testLeadingAudioOffsetKeepsThinkingUntilFirstWord() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "Hi. "), now: 1)
        d.handle(.runEnded(run: "r1", session: "main"), now: 1.1)
        let req = d.takeSpeechRequests()[0]
        _ = d.tick(now: 2)
        d.speechStarted(id: req.id, words: [WordTiming(text: "Hi.", start: 0.3, end: 0.7)], now: 2.5)
        let s = d.tick(now: 2.6)            // t=0.1 < 0.3 — leading silence
        XCTAssertEqual(s.phase, .thinking)  // no word heard yet
        XCTAssertNil(s.word)
        let s2 = d.tick(now: 2.85)          // t=0.35 ≥ 0.3
        XCTAssertEqual(s2.phase, .speaking)
        XCTAssertEqual(s2.word, "Hi.")
        d.speechFinished(id: req.id, now: 3.3)
        XCTAssertEqual(d.tick(now: 3.4).phase, .settling)
    }

    func testEmptyTimelineDoesNotStrandTheMachine() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "Hi. "), now: 1)
        d.handle(.runEnded(run: "r1", session: "main"), now: 1.1)
        let req = d.takeSpeechRequests()[0]
        _ = d.tick(now: 2)
        d.speechStarted(id: req.id, words: [], now: 2.5)
        XCTAssertEqual(d.tick(now: 2.6).phase, .thinking)   // nothing selectable
        d.speechFinished(id: req.id, now: 3)
        XCTAssertEqual(d.tick(now: 3.1).phase, .settling)   // recovered
    }

    func testDropPendingSpeechSkipsBacklogButResumesLive() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        // Backlog queued while Ziel sat on a hidden Space (the render loop, and
        // thus the speech pump, was paused — but gateway text kept arriving):
        d.handle(.textDelta(run: "r1", session: "main", text: "One. Two. Three. "), now: 1)

        d.dropPendingSpeech(now: 5)
        XCTAssertEqual(d.takeSpeechRequests(), [], "missed backlog is skipped, not replayed")

        // Text arriving after returning is spoken live:
        d.handle(.textDelta(run: "r1", session: "main", text: "Four. "), now: 6)
        XCTAssertEqual(d.takeSpeechRequests().map(\.text), ["Four."], "live text after return is spoken")
    }

    func testDropPendingSpeechDoesNotStrandTheFace() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "One. Two. "), now: 1)
        d.handle(.runEnded(run: "r1", session: "main"), now: 1.1)
        _ = d.takeSpeechRequests()
        // Swiped away, then back after the run already ended: nothing left to say.
        d.dropPendingSpeech(now: 5)
        XCTAssertEqual(d.tick(now: 5.1).phase, .settling)   // winds down, not stuck "busy"
    }

    func testDropPendingSpeechClearsBackgroundRunPending() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        // r1 is focused; r2 (non-focused) buffers its text in `runs[r2].pending`
        // while Ziel sits on a hidden Space.
        d.handle(.textDelta(run: "r1", session: "main", text: "First. "), now: 1)
        d.handle(.textDelta(run: "r2", session: "main", text: "Background reply. "), now: 1.1)
        _ = d.takeSpeechRequests()   // drain r1's queued sentence

        // Swipe back: the drop must also discard the hidden-Space text buffered on
        // the non-focused run, or run adoption replays it later (the catch-up bug).
        d.dropPendingSpeech(now: 2)

        d.handle(.runEnded(run: "r1", session: "main"), now: 2.1)
        d.handle(.runEnded(run: "r2", session: "main"), now: 2.2)
        var spoken = Set<String>()
        for t in stride(from: 2.2, through: 12.0, by: 0.1) {
            _ = d.tick(now: t)
            spoken.formUnion(d.takeSpeechRequests().map(\.text))
        }
        XCTAssertFalse(spoken.contains("Background reply."),
                       "text that arrived on a hidden Space must not be replayed via run adoption")
    }
}
