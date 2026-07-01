import XCTest

final class AmplitudeEnvelopeTests: XCTestCase {
    private func pcm(_ samples: [Int16]) -> Data {
        var d = Data(capacity: samples.count * 2)
        for s in samples {
            let u = UInt16(bitPattern: s)
            d.append(UInt8(u & 0xff)); d.append(UInt8(u >> 8))
        }
        return d
    }

    func testSilenceIsZero() {
        let env = AmplitudeEnvelope.from(pcm: pcm([Int16](repeating: 0, count: 2400)),
                                         sampleRate: 24000, rate: 60)
        XCTAssertFalse(env.isEmpty)
        XCTAssertEqual(env.max() ?? 1, 0, accuracy: 0.0001)
    }

    func testLoudToneIsHigh() {
        let env = AmplitudeEnvelope.from(pcm: pcm([Int16](repeating: 16000, count: 2400)),
                                         sampleRate: 24000, rate: 60)
        XCTAssertGreaterThan(env.max() ?? 0, 0.5)
        XCTAssertLessThanOrEqual(env.max() ?? 2, 1.0)
    }

    func testSampleCountIsCeilFramesOverWindow() {
        // 2400 frames @ 24000Hz, rate 60 → window 400 → 6 windows.
        let env = AmplitudeEnvelope.from(pcm: pcm([Int16](repeating: 100, count: 2400)),
                                         sampleRate: 24000, rate: 60)
        XCTAssertEqual(env.count, 6)
    }

    func testEmptyPCMIsEmpty() {
        XCTAssertTrue(AmplitudeEnvelope.from(pcm: Data(), sampleRate: 24000, rate: 60).isEmpty)
    }
}
