import XCTest

final class UtteranceSegmenterTests: XCTestCase {
    // Tiny 1-sample "frames" keep tests readable; the machine only counts frames.
    private func seg(_ c: SegmenterConfig = SegmenterConfig()) -> UtteranceSegmenter { UtteranceSegmenter(config: c) }
    private var cfg: SegmenterConfig {
        var c = SegmenterConfig(); c.startFrames = 2; c.hangoverFrames = 3; c.preRollFrames = 2; c.maxFrames = 10; return c
    }

    func testOpensAfterConsecutiveSpeechFramesWithPreRoll() {
        let s = seg(cfg)
        XCTAssertNil(s.push(frame: [1], prob: 0.1))   // pre-roll history
        XCTAssertNil(s.push(frame: [2], prob: 0.1))
        XCTAssertNil(s.push(frame: [3], prob: 0.9))   // 1st speech frame — not yet open
        XCTAssertEqual(s.push(frame: [4], prob: 0.9), .started)  // 2nd — opens
        XCTAssertTrue(s.isOpen)
    }

    func testClosesAfterHangoverAndEmitsSamplesIncludingPreRoll() {
        let s = seg(cfg)
        _ = s.push(frame: [1], prob: 0.1); _ = s.push(frame: [2], prob: 0.1)
        _ = s.push(frame: [3], prob: 0.9); _ = s.push(frame: [4], prob: 0.9)  // opens at [4]
        _ = s.push(frame: [5], prob: 0.9)
        XCTAssertNil(s.push(frame: [6], prob: 0.1))   // hangover 1
        XCTAssertNil(s.push(frame: [7], prob: 0.1))   // hangover 2
        guard case .utterance(let samples)? = s.push(frame: [8], prob: 0.1) else {  // hangover 3 → close
            return XCTFail("expected utterance")
        }
        XCTAssertEqual(samples, [1, 2, 3, 4, 5, 6, 7, 8])  // pre-roll [1,2] + speech + hangover
        XCTAssertFalse(s.isOpen)
    }

    func testSpeechInsideHangoverKeepsUtteranceOpen() {
        let s = seg(cfg)
        _ = s.push(frame: [1], prob: 0.9); _ = s.push(frame: [2], prob: 0.9)  // opens
        _ = s.push(frame: [3], prob: 0.1); _ = s.push(frame: [4], prob: 0.1)  // 2 silent
        XCTAssertNil(s.push(frame: [5], prob: 0.9))   // speech resets hangover
        XCTAssertTrue(s.isOpen)
    }

    func testHardCapCloses() {
        var c = cfg; c.maxFrames = 4
        let s = seg(c)
        _ = s.push(frame: [1], prob: 0.9); _ = s.push(frame: [2], prob: 0.9)  // open (2 frames so far)
        _ = s.push(frame: [3], prob: 0.9)
        guard case .utterance? = s.push(frame: [4], prob: 0.9) else { return XCTFail("expected cap close") }
        XCTAssertFalse(s.isOpen)
    }

    func testInterruptedStartRequiresConsecutive() {
        let s = seg(cfg)
        _ = s.push(frame: [1], prob: 0.9)             // 1 speech
        XCTAssertNil(s.push(frame: [2], prob: 0.1))   // broken streak
        XCTAssertNil(s.push(frame: [3], prob: 0.9))   // 1 again
        XCTAssertEqual(s.push(frame: [4], prob: 0.9), .started)
    }

    func testResetDropsEverything() {
        let s = seg(cfg)
        _ = s.push(frame: [1], prob: 0.9); _ = s.push(frame: [2], prob: 0.9)
        s.reset()
        XCTAssertFalse(s.isOpen)
        XCTAssertNil(s.push(frame: [9], prob: 0.1))
    }
}
