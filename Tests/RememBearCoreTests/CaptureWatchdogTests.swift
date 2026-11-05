import XCTest
@testable import RememBearCore

final class CaptureWatchdogTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testAReadThatFinishesInTimeIsKept() {
        var w = CaptureWatchdog()
        let token = w.begin(at: t0)
        XCTAssertEqual(w.check(at: t0.addingTimeInterval(10), lastRelaunch: nil), .reading)
        XCTAssertTrue(w.finish(token, at: t0.addingTimeInterval(12)))
        XCTAssertEqual(w.check(at: t0.addingTimeInterval(100), lastRelaunch: nil), .idle)
    }

    // 3 Nov 2026: one Vision read never returned, and as only one read runs
    // at a time no window was recorded for two days.
    func testAStuckReadLetsWindowsBeRecordedWithoutText() {
        var w = CaptureWatchdog(slow: 30, relaunchAfter: 600)
        let token = w.begin(at: t0)
        XCTAssertEqual(w.check(at: t0.addingTimeInterval(31), lastRelaunch: nil), .stuck)
        // It's left to finish (a first read can wait minutes on the Neural
        // Engine compiling its model), but what it read is stale by then.
        XCTAssertFalse(w.finish(token, at: t0.addingTimeInterval(90)))
        XCTAssertEqual(w.check(at: t0.addingTimeInterval(91), lastRelaunch: nil), .idle)
    }

    func testAReadStuckForLongRelaunchesAtMostOnceAnHour() {
        var w = CaptureWatchdog(slow: 30, relaunchAfter: 600, relaunchAtMostEvery: 3600)
        _ = w.begin(at: t0)
        let later = t0.addingTimeInterval(601)
        XCTAssertEqual(w.check(at: later, lastRelaunch: nil), .relaunch)
        XCTAssertEqual(w.check(at: later, lastRelaunch: t0.addingTimeInterval(-2000)), .stuck)
        XCTAssertEqual(w.check(at: later, lastRelaunch: t0.addingTimeInterval(-3000)), .relaunch)
    }

    func testOnlyTheCurrentReadIsAccepted() {
        var w = CaptureWatchdog()
        let token = w.begin(at: t0)
        XCTAssertFalse(w.finish(token + 1, at: t0))
        XCTAssertTrue(w.finish(token, at: t0))
        XCTAssertFalse(w.finish(token, at: t0))
    }
}
