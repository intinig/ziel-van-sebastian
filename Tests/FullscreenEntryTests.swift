import XCTest

final class FullscreenEntryTests: XCTestCase {
    func testFirstVerificationIsThreeSecondsAfterTheRequest() {
        var entry = FullscreenEntry()
        XCTAssertEqual(entry.requested(), 3)
    }

    func testVerificationDelayDoublesAndCapsAtSixtySeconds() {
        var entry = FullscreenEntry()
        let delays = (0..<7).map { _ in entry.requested() }
        XCTAssertEqual(delays, [3, 6, 12, 24, 48, 60, 60])
    }

    func testRequestsAgainWhenStillWindowedAtVerification() {
        // The login-time case: macOS dropped the request, nothing happened.
        var entry = FullscreenEntry()
        _ = entry.requested()
        XCTAssertTrue(entry.shouldRequest(isFullscreen: false))
    }

    func testNoRequestWhenAlreadyFullscreen() {
        var entry = FullscreenEntry()
        _ = entry.requested()
        XCTAssertFalse(entry.shouldRequest(isFullscreen: true))
    }

    func testNeverRequestsAgainOnceFullscreenWasReached() {
        // Leaving fullscreen on purpose after it worked must stick.
        var entry = FullscreenEntry()
        _ = entry.requested()
        entry.didEnter()
        XCTAssertFalse(entry.shouldRequest(isFullscreen: false))
    }

    func testDoesNotToggleWhileATransitionIsInFlight() {
        // toggleFullScreen is a toggle: re-requesting mid-transition would exit fullscreen.
        var entry = FullscreenEntry()
        _ = entry.requested()
        entry.willEnter()
        XCTAssertFalse(entry.shouldRequest(isFullscreen: false))
    }

    func testRequestsAgainAfterAFailedTransition() {
        var entry = FullscreenEntry()
        _ = entry.requested()
        entry.willEnter()
        entry.didFail()
        XCTAssertTrue(entry.shouldRequest(isFullscreen: false))
    }
}
