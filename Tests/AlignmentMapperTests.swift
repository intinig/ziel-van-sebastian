import XCTest

final class AlignmentMapperTests: XCTestCase {
    func testGroupsCharactersIntoWords() {
        let a = ElevenLabsAlignment(
            characters: ["H", "i", " ", "y", "o", "u", "."],
            characterStartTimesSeconds: [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
            characterEndTimesSeconds: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
        )
        XCTAssertEqual(AlignmentMapper.words(from: a), [
            WordTiming(text: "Hi", start: 0.0, end: 0.2),
            WordTiming(text: "you.", start: 0.3, end: 0.7),
        ])
    }

    func testIgnoresLeadingTrailingAndRepeatedWhitespace() {
        let a = ElevenLabsAlignment(
            characters: [" ", "a", " ", " ", "b", " "],
            characterStartTimesSeconds: [0, 0.1, 0.2, 0.3, 0.4, 0.5],
            characterEndTimesSeconds: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        )
        XCTAssertEqual(AlignmentMapper.words(from: a), [
            WordTiming(text: "a", start: 0.1, end: 0.2),
            WordTiming(text: "b", start: 0.4, end: 0.5),
        ])
    }

    func testDecodesElevenLabsJSON() throws {
        let json = """
        {"characters": ["H", "i"],
         "character_start_times_seconds": [0.0, 0.1],
         "character_end_times_seconds": [0.1, 0.2]}
        """
        let a = try JSONDecoder().decode(ElevenLabsAlignment.self, from: Data(json.utf8))
        XCTAssertEqual(a.characters, ["H", "i"])
        XCTAssertEqual(AlignmentMapper.words(from: a),
                       [WordTiming(text: "Hi", start: 0.0, end: 0.2)])
    }

    func testMismatchedArrayLengthsAreClamped() {
        let a = ElevenLabsAlignment(
            characters: ["a", "b", "c"],
            characterStartTimesSeconds: [0, 0.1],
            characterEndTimesSeconds: [0.1, 0.2]
        )
        XCTAssertEqual(AlignmentMapper.words(from: a),
                       [WordTiming(text: "ab", start: 0, end: 0.2)])
    }
}
