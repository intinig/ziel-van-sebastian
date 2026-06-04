import XCTest

final class DirectorTests: XCTestCase {
    private func makeDirector() -> Director {
        // classic keeps the green/amber tint assertions below meaningful.
        var look = LookConfig()
        look.theme = "classic"
        return Director(config: ZielConfig(), look: try! ResolvedLook.resolve(look))
    }

    func testStartsOffline() {
        let d = makeDirector()
        XCTAssertEqual(d.tick(now: 0).phase, .offline(auth: false))
    }

    func testConnectionUpGoesIdle() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 1)
        XCTAssertEqual(d.tick(now: 1).phase, .idle)
    }

    func testRunStartedWakesThenThinks() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "r1", session: "main"), now: 10)
        XCTAssertEqual(d.tick(now: 10.1).phase, .waking)
        XCTAssertEqual(d.tick(now: 10.5).phaseProgress, 0.5 / 0.8, accuracy: 0.01)
        XCTAssertEqual(d.tick(now: 10.9).phase, .thinking)
    }

    func testToolHintShowsAndExpires() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "r1", session: "main"), now: 10)
        _ = d.tick(now: 11)   // → thinking
        d.handle(.toolStarted(run: "r1", session: "main", tool: "read"), now: 11)
        XCTAssertEqual(d.tick(now: 11.1).hint, "READING…")
        XCTAssertNil(d.tick(now: 14).hint)   // 11 + 2.5 hold < 14
    }

    func testTextStreamsAsWords() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "r1", session: "main"), now: 10)
        d.handle(.textDelta(run: "r1", session: "main", text: "hello world "), now: 10.2)
        let s = d.tick(now: 11)   // waking done → thinking → speaking pops word
        XCTAssertEqual(s.phase, .speaking)
        XCTAssertEqual(s.word, "hello")
        // base hold 280ms: still "hello" at 11.2, "world" at 11.3
        XCTAssertEqual(d.tick(now: 11.2).word, "hello")
        XCTAssertEqual(d.tick(now: 11.3).word, "world")
    }

    func testRunEndAndDrainSettlesToIdle() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "r1", session: "main"), now: 10)
        d.handle(.textDelta(run: "r1", session: "main", text: "done"), now: 10.2)
        d.handle(.runEnded(run: "r1", session: "main"), now: 10.4)   // flushes "done"
        let s = d.tick(now: 11)
        XCTAssertEqual(s.phase, .speaking)
        XCTAssertEqual(s.word, "done")
        let after = d.tick(now: 11.4)        // word hold elapsed, queue empty, run over
        XCTAssertEqual(after.phase, .settling)
        XCTAssertEqual(d.tick(now: 12.7).phase, .idle)   // 11.4 + 1.2 settling
    }

    func testSpeakingLocksFocusUntilDrained() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "a", session: "s1"), now: 10)
        d.handle(.runStarted(run: "b", session: "s2"), now: 10)
        d.handle(.textDelta(run: "a", session: "s1", text: "alpha "), now: 10.1)
        d.handle(.textDelta(run: "b", session: "s2", text: "beta "), now: 10.2)
        d.handle(.runEnded(run: "a", session: "s1"), now: 10.3)
        d.handle(.runEnded(run: "b", session: "s2"), now: 10.3)
        XCTAssertEqual(d.tick(now: 11).word, "alpha")     // a focused first
        XCTAssertEqual(d.tick(now: 11.3).word, "beta")    // then b's text, no interleave
        XCTAssertEqual(d.tick(now: 11.7).phase, .settling)
    }

    func testQueueDrainedRunActiveReturnsToThinking() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "r1", session: "main"), now: 10)
        d.handle(.textDelta(run: "r1", session: "main", text: "wait "), now: 10.1)
        XCTAssertEqual(d.tick(now: 11).word, "wait")
        XCTAssertEqual(d.tick(now: 11.4).phase, .thinking)   // drained, run not ended
    }

    func testImplicitRunFromTextDelta() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "ghost", session: "s", text: "boo "), now: 5)
        XCTAssertEqual(d.tick(now: 5.1).phase, .waking)
        XCTAssertEqual(d.tick(now: 6).word, "boo")
    }

    func testDozeAfterIdlePeriod() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        XCTAssertFalse(d.tick(now: 500).dozing)
        XCTAssertTrue(d.tick(now: 601).dozing)
    }

    func testOfflineStates() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.connectionDown(auth: true), now: 5)
        XCTAssertEqual(d.tick(now: 6).phase, .offline(auth: true))
        d.handle(.connectionUp, now: 7)
        XCTAssertEqual(d.tick(now: 7).phase, .idle)
    }

    func testTintLerpsThroughWaking() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        let green = ColorRGB(hex: "#41ff6a")
        XCTAssertEqual(d.tick(now: 1).tint, green)
        d.handle(.runStarted(run: "r", session: "s"), now: 10)
        let mid = d.tick(now: 10.4).tint                     // halfway green→amber
        let expected = ColorRGB.lerp(green, ColorRGB(hex: "#ffb000"), 0.5)
        XCTAssertEqual(mid.r, expected.r, accuracy: 0.01)
        XCTAssertEqual(mid.g, expected.g, accuracy: 0.01)
    }

    func testThinkingRunEndsWithoutTextSettles() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "r1", session: "main"), now: 10)
        XCTAssertEqual(d.tick(now: 11).phase, .thinking)
        d.handle(.runEnded(run: "r1", session: "main"), now: 11.5)   // no text ever
        XCTAssertEqual(d.tick(now: 12).phase, .settling)
        XCTAssertEqual(d.tick(now: 13.3).phase, .idle)
    }

    func testPendingRunAdoptedAfterFocusedRunDiesInThinking() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "a", session: "s1"), now: 10)
        d.handle(.runStarted(run: "b", session: "s2"), now: 10)
        d.handle(.textDelta(run: "a", session: "s1", text: "hi "), now: 10.05)
        d.handle(.textDelta(run: "b", session: "s2", text: "yo "), now: 10.1)
        XCTAssertEqual(d.tick(now: 11).word, "hi")                    // a focused
        XCTAssertEqual(d.tick(now: 11.3).phase, .thinking)            // a drained, still active
        d.handle(.runEnded(run: "b", session: "s2"), now: 11.35)      // b ends, pending kept
        d.handle(.runEnded(run: "a", session: "s1"), now: 11.4)       // focused a dies in thinking
        XCTAssertEqual(d.tick(now: 11.5).word, "yo")                  // b adopted from thinking
        XCTAssertEqual(d.tick(now: 11.85).phase, .settling)
    }

    func testToolOnlyRunsDoNotAccumulate() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        for i in 0..<50 {
            let t = Double(i)
            d.handle(.runStarted(run: "r\(i)", session: "s"), now: 100 + t)
            d.handle(.toolStarted(run: "r\(i)", session: "s", tool: "exec"), now: 100.1 + t)
            d.handle(.runEnded(run: "r\(i)", session: "s"), now: 100.2 + t)
        }
        XCTAssertEqual(d.runCount, 0)
    }
}
