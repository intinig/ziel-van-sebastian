import XCTest

final class FaceAnimationTests: XCTestCase {
    func testBlinkMostlyOpenDipsClosed() {
        XCTAssertEqual(FaceAnimation.blinkScale(at: 1.0), 1.0, accuracy: 0.01)
        XCTAssertEqual(FaceAnimation.blinkScale(at: 4.0), 1.0, accuracy: 0.01)
        let closed = FaceAnimation.blinkScale(at: 6.93)
        XCTAssertLessThan(closed, 0.3)
        for t in stride(from: 0.0, to: 14.0, by: 0.05) {
            let v = FaceAnimation.blinkScale(at: t)
            XCTAssertGreaterThanOrEqual(v, 0.05)
            XCTAssertLessThanOrEqual(v, 1.0)
        }
    }

    func testWanderBounded() {
        for t in stride(from: 0.0, to: 32.0, by: 0.1) {
            let dx = FaceAnimation.wanderOffset(at: t)
            XCTAssertLessThanOrEqual(abs(dx), 1.5)
        }
        XCTAssertEqual(FaceAnimation.wanderOffset(at: 0), 0, accuracy: 0.01)
    }

    func testBreatheGentle() {
        for t in stride(from: 0.0, to: 12.0, by: 0.1) {
            let s = FaceAnimation.breatheScale(at: t)
            XCTAssertGreaterThan(s, 0.97)
            XCTAssertLessThan(s, 1.03)
        }
    }

    func testThinkingDotsAppearOneByOne() {
        // 2s cycle, hard steps: blank, 1, 2, 3, blank.
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 0.0), 0)   // p = 0.0
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 0.4), 1)   // p = 0.2
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 1.0), 2)   // p = 0.5
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 1.5), 3)   // p = 0.75
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 1.8), 0)   // p = 0.9
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 2.4), 1)   // wraps: p = 0.2
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 10.5, period: 1.0), 2) // p = 0.5
    }

    func testEyesUpOffsetOnlyWhenThinking() {
        let off = FaceAnimation.eyesUpOffset(at: 2.5)
        XCTAssertLessThanOrEqual(off.dy, 0)
        XCTAssertGreaterThanOrEqual(off.dy, -1.2)
    }

    func testZzAlphaCycles() {
        for t in stride(from: 0.0, to: 10.0, by: 0.1) {
            let a = FaceAnimation.zzAlpha(at: t)
            XCTAssertGreaterThanOrEqual(a, 0)
            XCTAssertLessThanOrEqual(a, 1)
        }
    }

    func testWakeBlinkIsADoubleBlink() {
        XCTAssertEqual(FaceAnimation.wakeBlinkScale(progress: 0), 1.0, accuracy: 0.05)
        XCTAssertEqual(FaceAnimation.wakeBlinkScale(progress: 1), 1.0, accuracy: 0.05)
        XCTAssertLessThan(FaceAnimation.wakeBlinkScale(progress: 0.25), 0.3)
        XCTAssertLessThan(FaceAnimation.wakeBlinkScale(progress: 0.75), 0.3)
        XCTAssertGreaterThan(FaceAnimation.wakeBlinkScale(progress: 0.5), 0.9)
        for p in stride(from: 0.0, through: 1.0, by: 0.02) {
            let v = FaceAnimation.wakeBlinkScale(progress: p)
            XCTAssertGreaterThanOrEqual(v, 0.05)
            XCTAssertLessThanOrEqual(v, 1.0)
        }
    }
}
