import XCTest

final class SpeechCoordinatorTests: XCTestCase {
    private final class FakeSynth: SpeechSynthesizing {
        var fetches: [(req: SpeechRequest, prev: [String], completion: (Result<SpokenAudio, Error>) -> Void)] = []
        var played: [SpokenAudio] = []
        var playCallbacks: [(onStarted: () -> Void, onFinished: () -> Void)] = []
        var stopped = 0

        func fetch(_ request: SpeechRequest, previousRequestIDs: [String],
                   completion: @escaping (Result<SpokenAudio, Error>) -> Void) {
            fetches.append((request, previousRequestIDs, completion))
        }
        func play(_ audio: SpokenAudio, volume: Double,
                  onStarted: @escaping () -> Void, onFinished: @escaping () -> Void) {
            played.append(audio)
            playCallbacks.append((onStarted, onFinished))
        }
        func stopPlayback() { stopped += 1 }
    }

    private func makeDirector() -> Director {
        var cfg = ZielConfig()
        cfg.speech.enabled = true
        var look = LookConfig()
        look.theme = "classic"
        return Director(config: cfg, look: try! ResolvedLook.resolve(look))
    }

    private func audio(_ words: [WordTiming], rid: String? = nil) -> SpokenAudio {
        SpokenAudio(requestID: rid, words: words, pcm: Data(count: 4), sampleRate: 24_000)
    }

    func testPlaysInRequestOrderEvenIfFetchesResolveOutOfOrder() {
        let d = makeDirector()
        let synth = FakeSynth()
        let co = SpeechCoordinator(director: d, synth: synth, volume: 1, now: { 5 })
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r", session: "m", text: "One. Two. "), now: 0.1)
        co.pump()
        XCTAssertEqual(synth.fetches.count, 2)
        synth.fetches[1].completion(.success(audio([WordTiming(text: "Two.", start: 0, end: 0.4)])))
        XCTAssertTrue(synth.played.isEmpty)                  // head not ready yet
        synth.fetches[0].completion(.success(audio([WordTiming(text: "One.", start: 0, end: 0.4)])))
        XCTAssertEqual(synth.played.count, 1)
        XCTAssertEqual(synth.played[0].words.first?.text, "One.")
        synth.playCallbacks[0].onStarted()
        XCTAssertEqual(d.tick(now: 5.1).word, "One.")        // director got speechStarted
        synth.playCallbacks[0].onFinished()
        XCTAssertEqual(synth.played.count, 2)                // second sentence follows
    }

    func testFetchFailureReportsAndPlaysNext() {
        let d = makeDirector()
        let synth = FakeSynth()
        let co = SpeechCoordinator(director: d, synth: synth, volume: 1, now: { 5 })
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r", session: "m", text: "One. Two. "), now: 0.1)
        co.pump()
        synth.fetches[0].completion(.failure(NSError(domain: "t", code: 1)))
        synth.fetches[1].completion(.success(audio([WordTiming(text: "Two.", start: 0, end: 0.4)])))
        XCTAssertEqual(synth.played.count, 1)
        XCTAssertEqual(synth.played[0].words.first?.text, "Two.")
        // Director shows sentence one as paced fallback before the timeline:
        XCTAssertEqual(d.tick(now: 5.0).word, "One.")
    }

    func testPreviousRequestIDsStitchUpToThree() {
        // Note: single-letter words ("A.", "B.") are treated as initials by
        // SentenceChunker and never emitted, so use multi-character sentences.
        let d = makeDirector()
        let synth = FakeSynth()
        let co = SpeechCoordinator(director: d, synth: synth, volume: 1, now: { 5 })
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r", session: "m", text: "Hello. "), now: 0.1)
        co.pump()
        XCTAssertEqual(synth.fetches.count, 1)
        synth.fetches[0].completion(.success(audio([WordTiming(text: "Hello.", start: 0, end: 0.1)], rid: "x1")))
        d.handle(.textDelta(run: "r", session: "m", text: "World. "), now: 0.2)
        co.pump()
        XCTAssertEqual(synth.fetches[1].prev, ["x1"])
    }

    func testCircuitOpensAfterThreeConsecutiveFailures() {
        let d = makeDirector()
        let synth = FakeSynth()
        let co = SpeechCoordinator(director: d, synth: synth, volume: 1, now: { 5 })
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r", session: "m", text: "One. Two. Three. "), now: 0.1)
        co.pump()
        XCTAssertEqual(synth.fetches.count, 3)
        for f in synth.fetches { f.completion(.failure(NSError(domain: "t", code: 1))) }
        d.handle(.textDelta(run: "r", session: "m", text: "Four. "), now: 0.2)
        co.pump()
        XCTAssertEqual(synth.fetches.count, 3)               // circuit open: no new network calls
        // "Four." was failed straight to the director → it displays via the pacer.
        var words = Set<String>()
        for t in stride(from: 1.0, through: 8.0, by: 0.1) {
            if let w = d.tick(now: t).word { words.insert(w) }
        }
        XCTAssertTrue(words.contains("Four."))
    }

    func testCancelAllStopsPlaybackAndIgnoresStaleCompletions() {
        let d = makeDirector()
        let synth = FakeSynth()
        let co = SpeechCoordinator(director: d, synth: synth, volume: 1, now: { 5 })
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r", session: "m", text: "One. "), now: 0.1)
        co.pump()
        co.cancelAll()
        XCTAssertEqual(synth.stopped, 1)
        synth.fetches[0].completion(.success(audio([WordTiming(text: "One.", start: 0, end: 0.4)])))
        XCTAssertTrue(synth.played.isEmpty)                  // stale generation dropped
    }
}
