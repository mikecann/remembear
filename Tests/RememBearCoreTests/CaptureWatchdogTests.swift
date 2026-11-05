import XCTest
@testable import RememBearCore

/// Times are seconds of system uptime, which stands still while the Mac
/// sleeps and can't be set back like the wall clock.
final class CaptureWatchdogTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testAReadThatFinishesInTimeIsKept() {
        var w = CaptureWatchdog()
        let token = w.begin(uptime: 100)
        XCTAssertEqual(w.check(uptime: 110, now: now, lastRelaunch: nil), .reading)
        XCTAssertTrue(w.finish(token, uptime: 112))
        XCTAssertEqual(w.check(uptime: 200, now: now, lastRelaunch: nil), .idle)
    }

    // 3 Nov 2026: one Vision read never returned, and as only one read runs
    // at a time no window was recorded for two days.
    func testAStuckReadLetsWindowsBeRecordedWithoutText() {
        var w = CaptureWatchdog(slow: 30, relaunchAfter: 600)
        let token = w.begin(uptime: 100)
        XCTAssertEqual(w.check(uptime: 131, now: now, lastRelaunch: nil), .stuck)
        // It's left to finish (a first read can wait minutes on the Neural
        // Engine compiling its model), but what it read is stale by then.
        XCTAssertFalse(w.finish(token, uptime: 190))
        XCTAssertEqual(w.check(uptime: 191, now: now, lastRelaunch: nil), .idle)
    }

    func testOnceOverdueAReadStaysStale() {
        var w = CaptureWatchdog(slow: 30)
        let token = w.begin(uptime: 100)
        XCTAssertEqual(w.check(uptime: 131, now: now, lastRelaunch: nil), .stuck)
        // Even if it then reports in as though it were quick.
        XCTAssertFalse(w.finish(token, uptime: 105))
    }

    func testAReadStuckForLongRelaunchesAtMostOnceAnHour() {
        var w = CaptureWatchdog(slow: 30, relaunchAfter: 600, relaunchAtMostEvery: 3600)
        _ = w.begin(uptime: 100)
        XCTAssertEqual(w.check(uptime: 701, now: now, lastRelaunch: nil), .relaunch)
        XCTAssertEqual(w.check(uptime: 701, now: now, lastRelaunch: now.addingTimeInterval(-2000)), .stuck)
        XCTAssertEqual(w.check(uptime: 701, now: now, lastRelaunch: now.addingTimeInterval(-3600)), .relaunch)
    }

    func testOnlyTheCurrentReadIsAccepted() {
        var w = CaptureWatchdog()
        let token = w.begin(uptime: 0)
        XCTAssertFalse(w.finish(token + 1, uptime: 0))
        XCTAssertTrue(w.finish(token, uptime: 0))
        XCTAssertFalse(w.finish(token, uptime: 0))
    }
}
