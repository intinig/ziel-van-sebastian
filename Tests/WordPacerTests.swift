import XCTest

final class WordPacerTests: XCTestCase {
    func testSplitsAcrossChunksAndFlushes() {
        let p = WordPacer(config: PacingConfig())
        p.feed("hel")
        XCTAssertNil(p.nextWord())              // "hel" might continue
        p.feed("lo world")
        XCTAssertEqual(p.nextWord()?.text, "hello")
        XCTAssertNil(p.nextWord())              // "world" might continue
        p.endOfText()
        XCTAssertEqual(p.nextWord()?.text, "world")
        XCTAssertNil(p.nextWord())
    }

    func testBaseHold() {
        let p = WordPacer(config: PacingConfig())
        p.feed("ok ")
        XCTAssertEqual(p.nextWord()!.holdMs, 280, accuracy: 0.5)
    }

    func testLongWordHold() {
        let p = WordPacer(config: PacingConfig())
        p.feed("extraordinary ")                 // 13 chars → 280 + 7*60
        XCTAssertEqual(p.nextWord()!.holdMs, 700, accuracy: 0.5)
    }

    func testSentencePause() {
        let p = WordPacer(config: PacingConfig())
        p.feed("done. ")
        // "done." = 5 chars ≤ threshold → 280 + 320
        XCTAssertEqual(p.nextWord()!.holdMs, 600, accuracy: 0.5)
    }

    func testClausePause() {
        let p = WordPacer(config: PacingConfig())
        p.feed("first, ")
        // "first," = 6 chars ≤ threshold → 280 + 150
        XCTAssertEqual(p.nextWord()!.holdMs, 430, accuracy: 0.5)
    }

    func testBacklogCatchup() {
        let p = WordPacer(config: PacingConfig())
        p.feed(String(repeating: "a ", count: 100))    // 100 one-char words
        // After popping one, backlog = 99 ≥ catchupFull(80) → factor = minFactor
        XCTAssertEqual(p.nextWord()!.holdMs, 280 * 0.45, accuracy: 0.5)
    }

    func testNoCatchupBelowStart() {
        let p = WordPacer(config: PacingConfig())
        p.feed("a b c ")                                // backlog after pop = 2 < 10
        XCTAssertEqual(p.nextWord()!.holdMs, 280, accuracy: 0.5)
    }

    func testWhitespaceOnlyChunksIgnored() {
        let p = WordPacer(config: PacingConfig())
        p.feed("   \n  ")
        p.endOfText()
        XCTAssertNil(p.nextWord())
        XCTAssertTrue(p.isEmpty)
    }
}
