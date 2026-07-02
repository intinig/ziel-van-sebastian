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

    func testStopWhileSegmentOpenEmitsClosingVad() {
        let (p, events) = make(transcript: "x")
        p.segmenterEvent(.started)                 // opens a segment -> vad(true)
        p.handle(.stop, resetSegmenter: {})        // mid-segment stop must close it
        XCTAssertEqual(events(), [.vad(speaking: true), .vad(speaking: false)])
    }

    func testStopWithNoOpenSegmentEmitsNothing() {
        let (p, events) = make(transcript: "x")
        p.handle(.stop, resetSegmenter: {})
        XCTAssertEqual(events(), [])
    }

    func testUtteranceThenStopDoesNotDoubleClose() {
        let (p, events) = make(transcript: "")   // empty -> only vad(false) from utterance
        p.segmenterEvent(.started)
        p.segmenterEvent(.utterance([0.1]))        // closes the segment -> vad(false)
        p.handle(.stop, resetSegmenter: {})        // already closed -> no extra vad(false)
        XCTAssertEqual(events(), [.vad(speaking: true), .vad(speaking: false)])
    }
}
