import XCTest
@testable import RememBearCore

final class SetupTests: XCTestCase {
    func testCompleteOnlyWhenEverythingNeededIsOn() {
        XCTAssertTrue(SetupState(screenRecording: .granted, accessibility: .granted, chrome: .granted).isComplete)
        // No Chrome on this Mac: nothing to allow.
        XCTAssertTrue(SetupState(screenRecording: .granted, accessibility: .granted, chrome: .notNeeded).isComplete)
        XCTAssertFalse(SetupState(screenRecording: .missing, accessibility: .granted, chrome: .granted).isComplete)
        XCTAssertFalse(SetupState(screenRecording: .granted, accessibility: .denied, chrome: .granted).isComplete)
        // Chrome closed: it still has to be allowed once it's open.
        XCTAssertFalse(SetupState(screenRecording: .granted, accessibility: .granted, chrome: .waitingForApp).isComplete)
    }

    func testRemainingCountsWhatsLeft() {
        XCTAssertEqual(SetupState(screenRecording: .missing, accessibility: .denied, chrome: .waitingForApp).remaining, 3)
        XCTAssertEqual(SetupState(screenRecording: .granted, accessibility: .missing, chrome: .notNeeded).remaining, 1)
        XCTAssertEqual(SetupState(screenRecording: .granted, accessibility: .granted, chrome: .granted).remaining, 0)
    }
}
