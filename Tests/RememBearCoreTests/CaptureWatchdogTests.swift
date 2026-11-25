import XCTest
@testable import RememBearCore

/// Times are seconds of system uptime, which stands still while the Mac
/// sleeps and can't be set back like the wall clock.
final class CaptureWatchdogTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testAReadThatFinishesInTimeIsKept() {
        var w = CaptureWatchdog()
        XCTAssertFalse(w.busy)
        let token = w.begin(uptime: 100)
        XCTAssertTrue(w.busy)
        XCTAssertEqual(w.check(uptime: 110, now: now, lastRelaunch: nil), .reading)
        XCTAssertTrue(w.finish(token, uptime: 112))
        XCTAssertFalse(w.busy)
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

    // 24 Nov 2026: after a week running, every Vision read failed at once
    // (CRImageReaderError 1) while a fresh process read text fine, and
    // nothing was recorded until the app was restarted.
    func testReadsThatKeepFailingRelaunch() {
        var w = CaptureWatchdog(failingFor: 300, failuresBeforeRelaunch: 10)
        var t: TimeInterval = 100
        for _ in 0..<10 {
            let token = w.begin(uptime: t)
            XCTAssertTrue(w.finish(token, uptime: t + 0.2, outcome: .failed))
            XCTAssertEqual(w.check(uptime: t + 0.2, now: now, lastRelaunch: nil), .idle)
            t += 20
        }
        XCTAssertFalse(w.failing(uptime: t))
        // Ten failures, but not yet for five minutes.
        let token = w.begin(uptime: 400)
        XCTAssertTrue(w.finish(token, uptime: 400.2, outcome: .failed))
        XCTAssertTrue(w.failing(uptime: 401))
        XCTAssertEqual(w.check(uptime: 401, now: now, lastRelaunch: nil), .relaunch)
        // Still at most once an hour, so a broken system service can't loop.
        XCTAssertEqual(w.check(uptime: 401, now: now, lastRelaunch: now.addingTimeInterval(-2000)), .idle)
    }

    func testAGoodReadClearsTheFailures() {
        var w = CaptureWatchdog(failingFor: 300, failuresBeforeRelaunch: 3)
        for t in stride(from: 0.0, to: 600, by: 100) {
            let token = w.begin(uptime: t)
            _ = w.finish(token, uptime: t, outcome: .failed)
        }
        XCTAssertTrue(w.failing(uptime: 600))
        let token = w.begin(uptime: 600)
        _ = w.finish(token, uptime: 601)
        XCTAssertFalse(w.failing(uptime: 2000))
        XCTAssertEqual(w.check(uptime: 2000, now: now, lastRelaunch: nil), .idle)
    }

    func testAFewFailuresOverALongTimeDontRelaunch() {
        var w = CaptureWatchdog(failingFor: 300, failuresBeforeRelaunch: 10)
        let first = w.begin(uptime: 0)
        _ = w.finish(first, uptime: 0, outcome: .failed)
        let second = w.begin(uptime: 3000)
        _ = w.finish(second, uptime: 3000, outcome: .failed)
        XCTAssertEqual(w.check(uptime: 3001, now: now, lastRelaunch: nil), .idle)
    }

    // A slow first read (the Neural Engine compiling Vision's model) keeps
    // its ten minutes even after reads had been failing.
    func testFailuresDontCutShortARunningRead() {
        var w = CaptureWatchdog(slow: 30, relaunchAfter: 600, failingFor: 300, failuresBeforeRelaunch: 2)
        for t in [0.0, 100] {
            let token = w.begin(uptime: t)
            _ = w.finish(token, uptime: t, outcome: .failed)
        }
        _ = w.begin(uptime: 200)
        XCTAssertEqual(w.check(uptime: 220, now: now, lastRelaunch: nil), .reading)
        XCTAssertEqual(w.check(uptime: 400, now: now, lastRelaunch: nil), .stuck)
        XCTAssertEqual(w.check(uptime: 801, now: now, lastRelaunch: nil), .relaunch)
    }

    // A window that closed while it was read, or looked the same so Vision
    // never ran, says nothing about whether reading works.
    func testAReadThatReadNothingDoesntClearTheFailures() {
        var w = CaptureWatchdog(failingFor: 300, failuresBeforeRelaunch: 2)
        for t in [0.0, 100] {
            let token = w.begin(uptime: t)
            _ = w.finish(token, uptime: t, outcome: .failed)
        }
        let token = w.begin(uptime: 200)
        _ = w.finish(token, uptime: 200, outcome: .notRead)
        XCTAssertEqual(w.check(uptime: 301, now: now, lastRelaunch: nil), .relaunch)
    }
}
