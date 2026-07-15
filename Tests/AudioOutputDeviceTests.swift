import XCTest

final class AudioOutputDeviceTests: XCTestCase {
    func testEmptyNameReturnsNil() {
        XCTAssertNil(AudioOutputDevice.find(named: ""))
    }

    func testNonsenseNameReturnsNil() {
        XCTAssertNil(AudioOutputDevice.find(named: "no-such-device-\(UUID().uuidString)"))
    }
}
