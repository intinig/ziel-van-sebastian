import XCTest

final class SentenceChunkerTests: XCTestCase {
    func testSplitsCompleteSentences() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Hello world. How are you? Fine"),
                       ["Hello world.", "How are you?"])
        XCTAssertEqual(c.flush(), "Fine")
    }

    func testAccumulatesAcrossDeltas() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Hel"), [])
        XCTAssertEqual(c.feed("lo wor"), [])
        XCTAssertEqual(c.feed("ld. Next"), ["Hello world."])
        XCTAssertEqual(c.flush(), "Next")
    }

    func testTerminatorAtBufferEndWaitsForMoreText() {
        // A trailing "." might be "3." of "3.14" — no boundary until we see what follows.
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Wait."), [])
        XCTAssertEqual(c.feed(" Done. "), ["Wait.", "Done."])
    }

    func testDoesNotSplitAbbreviationsOrInitials() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Dr. Smith met J. Doe e.g. yesterday. Done "),
                       ["Dr. Smith met J. Doe e.g. yesterday.", "Done"])
    }

    func testDoesNotSplitDecimals() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Pi is 3.14 roughly. Yes "), ["Pi is 3.14 roughly.", "Yes"])
    }

    func testNewlineIsABoundary() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("First line\nSecond. "), ["First line", "Second."])
    }

    func testClosingQuoteStaysWithSentence() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("He said \"stop.\" Then left. "),
                       ["He said \"stop.\"", "Then left."])
    }

    func testFlushEmptyReturnsNil() {
        var c = SentenceChunker()
        _ = c.feed("Done. ")
        XCTAssertNil(c.flush())
    }
}
