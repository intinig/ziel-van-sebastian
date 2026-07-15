import XCTest

final class AudioOutputDeviceTests: XCTestCase {
    func testEmptyNameReturnsNil() {
        XCTAssertNil(AudioOutputDevice.find(named: ""))
    }

    func testNonsenseNameReturnsNil() {
        XCTAssertNil(AudioOutputDevice.find(named: "no-such-device-\(UUID().uuidString)"))
    }

    // Every real Mac (this project only ever runs `make test` on developer/
    // appliance hardware, never a headless CI runner) has a default output
    // device — even just the internal speakers — so this cannot flake here.
    // It only proves the CoreAudio query wiring works, not real playback;
    // the actual AudioUnitSetProperty reset in ElevenLabsTTS.play() is at the
    // same no-seam boundary as the device pin and is verified manually.
    func testSystemDefaultOutputReturnsADevice() {
        XCTAssertNotNil(AudioOutputDevice.systemDefaultOutput())
    }
}
