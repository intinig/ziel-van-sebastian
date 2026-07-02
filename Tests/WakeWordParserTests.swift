import XCTest

final class WakeWordParserTests: XCTestCase {
    func testMatchesAndStrips() {
        XCTAssertEqual(WakeWordParser.match(transcript: "Sebastian, what's the weather?", wakeWord: "Sebastian"),
                       "what's the weather?")
        XCTAssertEqual(WakeWordParser.match(transcript: " sebastian.  turn it up ", wakeWord: "Sebastian"),
                       "turn it up")
        XCTAssertEqual(WakeWordParser.match(transcript: "SEBASTIAN", wakeWord: "Sebastian"), "")
        XCTAssertEqual(WakeWordParser.match(transcript: "Sebastián, hola", wakeWord: "Sebastian"), "hola")
    }
    func testRejectsNonWake() {
        XCTAssertNil(WakeWordParser.match(transcript: "hey there Sebastian", wakeWord: "Sebastian"))
        XCTAssertNil(WakeWordParser.match(transcript: "sebastians car", wakeWord: "Sebastian"))
        XCTAssertNil(WakeWordParser.match(transcript: "", wakeWord: "Sebastian"))
    }
    func testExoticFoldingDoesNotTrap() {
        // "ﬆ" (U+FB06) folds to "st": the transcript is 8 graphemes but its fold
        // prefixes the 9-grapheme folded wake word — must return nil, not trap.
        XCTAssertNil(WakeWordParser.match(transcript: "Sebaﬆian", wakeWord: "Sebastian"))
    }
}
