import XCTest

final class VoicePipelineTests: XCTestCase {
    private func make(transcript: String) -> (VoicePipeline, () -> [VoiceEvent]) {
        var events: [VoiceEvent] = []
        let p = VoicePipeline(wakeWord: "Sebastian",
                              transcribe: { _ in transcript },
                              emit: { events.append($0) })
        return (p, { events })
    }

    func testArmedIgnoresNonWakeSpeech() {
        let (p, events) = make(transcript: "just chatting in the room")
        p.segmenterEvent(.started)
        p.segmenterEvent(.utterance([0.1]))
        XCTAssertEqual(events(), [.vad(speaking: true), .vad(speaking: false)])  // no heard/wake
    }

    func testArmedWakeWithCommandEmitsWakeAndHeard() {
        let (p, events) = make(transcript: "Sebastian, what's the weather")
        p.segmenterEvent(.utterance([0.1]))
        XCTAssertEqual(events(), [.vad(speaking: false), .wake, .heard(text: "what's the weather")])
    }

    func testArmedWakeOnlyEmitsWakeAndListening() {
        let (p, events) = make(transcript: "Sebastian")
        p.segmenterEvent(.utterance([0.1]))
        XCTAssertEqual(events(), [.vad(speaking: false), .wake, .listening])
    }

    func testListenModeForwardsEverythingAndStripsStrayWakeWord() {
        let (p, events) = make(transcript: "Sebastian turn it up")
        p.mode = .listen
        p.segmenterEvent(.utterance([0.1]))
        XCTAssertEqual(events(), [.vad(speaking: false), .heard(text: "turn it up")])
    }

    func testListenModeForwardsPlainSpeech() {
        let (p, events) = make(transcript: "and tomorrow?")
        p.mode = .followUp
        p.segmenterEvent(.utterance([0.1]))
        XCTAssertEqual(events(), [.vad(speaking: false), .heard(text: "and tomorrow?")])
    }

    func testEmptyTranscriptEmitsNothing() {
        let (p, events) = make(transcript: "  ")
        p.mode = .listen
        p.segmenterEvent(.utterance([0.1]))
        XCTAssertEqual(events(), [.vad(speaking: false)])
    }

    func testModeCommandUpdatesModeAndStopResets() {
        let (p, _) = make(transcript: "x")
        var didReset = false
        p.handle(.mode(.speaking), resetSegmenter: {})
        XCTAssertEqual(p.mode, .speaking)
        p.handle(.stop, resetSegmenter: { didReset = true })
        XCTAssertTrue(didReset)
    }
}
