import XCTest
@testable import RecallItCore

final class WindowAndScheduleTests: XCTestCase {
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testWindowsAlignToUTC() {
        let w = TimeWindow.containing(date("2026-10-29T06:27:41Z"), .tenMinutes)
        XCTAssertEqual(w.start, date("2026-10-29T06:20:00Z"))
        XCTAssertEqual(w.end, date("2026-10-29T06:30:00Z"))
        XCTAssertEqual(w.stamp, "2026-10-29T06-20-00")
        XCTAssertEqual(w.segmentID, "2026-10-29T06-20-00Z")
        XCTAssertEqual(TimeWindow.parseSegmentID("2026-10-29T06-20-00Z"), w)
        XCTAssertNil(TimeWindow.parseSegmentID("2026-10-29T06-21-00Z"))

        let six = TimeWindow.containing(date("2026-10-29T11:59:59Z"), .sixHours)
        XCTAssertEqual(six.start, date("2026-10-29T06:00:00Z"))
        XCTAssertEqual(six.tenMinuteWindows.count, 36)
        XCTAssertTrue(six.contains(w.start))
    }

    func testSummaryFileNamesMatchCodexAndAgentArchive() {
        let w = TimeWindow.containing(date("2026-10-29T06:20:00Z"), .tenMinutes)
        let name = SummaryFileName.make(w, tag: "WgFr")
        XCTAssertEqual(name, "2026-10-29T06-20-00-WgFr-10min-memory-summary.md")
        XCTAssertEqual(SummaryFileName.parse(name), w)
        XCTAssertEqual(SummaryFileName.parse("2026-10-29T00-00-00-UqkC-6h-memory-summary.md"),
                       TimeWindow(resolution: .sixHours, start: date("2026-10-29T00:00:00Z")))
        // A 6-hour file must start on a 6-hour boundary.
        XCTAssertNil(SummaryFileName.parse("2026-10-29T06-20-00-UqkC-6h-memory-summary.md"))
        XCTAssertNil(SummaryFileName.parse(".tmp-2026-10-29T06-20-00-WgFr-10min-memory-summary.md"))
        XCTAssertEqual(SummaryFileName.randomTag().count, 4)
    }

    func testTenMinuteWindowsAreDueAfterGraceAndRetry() {
        let a = TimeWindow.containing(date("2026-10-29T06:00:00Z"), .tenMinutes)
        let b = a.next, c = b.next
        let now = date("2026-10-29T06:21:00Z") // b ended 60s ago, c is open
        XCTAssertEqual(Schedule.dueTenMinute(segments: [a, b, c], summarized: [], retryAfter: [:], now: now), [a])
        XCTAssertEqual(Schedule.dueTenMinute(segments: [a, b, c], summarized: [a], retryAfter: [:], now: now.addingTimeInterval(60)), [b])
        XCTAssertEqual(Schedule.dueTenMinute(segments: [a], summarized: [], retryAfter: [a: now.addingTimeInterval(1)], now: now), [])
    }

    func testSixHourRollupWaitsForPendingChildren() {
        let six = TimeWindow(resolution: .sixHours, start: date("2026-10-29T00:00:00Z"))
        let child = six.tenMinuteWindows[3], last = six.tenMinuteWindows.last!
        let now = date("2026-10-29T06:11:00Z")
        XCTAssertEqual(Schedule.dueSixHour(tenMinuteSummaries: [child], sixHourSummaries: [], pendingTenMinute: [], now: now), [six])
        XCTAssertEqual(Schedule.dueSixHour(tenMinuteSummaries: [child], sixHourSummaries: [], pendingTenMinute: [last], now: now), [])
        XCTAssertEqual(Schedule.dueSixHour(tenMinuteSummaries: [child], sixHourSummaries: [six], pendingTenMinute: [], now: now), [])
        // Not before the grace period.
        XCTAssertEqual(Schedule.dueSixHour(tenMinuteSummaries: [child], sixHourSummaries: [], pendingTenMinute: [], now: date("2026-10-29T06:05:00Z")), [])
    }

    func testRawEventsExpireAfter48Hours() {
        let w = TimeWindow.containing(date("2026-10-27T06:00:00Z"), .tenMinutes)
        XCTAssertEqual(Schedule.expired([w], now: date("2026-10-29T06:09:00Z")), [])
        XCTAssertEqual(Schedule.expired([w], now: date("2026-10-29T06:11:00Z")), [w])
    }

    func testSettingsDefaultsAndPause() {
        let suite = "recall-it-tests-\(UUID().uuidString)"
        let s = Settings(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertEqual(s.tenMinuteModel, "haiku")
        XCTAssertEqual(s.sixHourModel, "sonnet")
        XCTAssertFalse(s.isPaused())
        s.pausedUntil = Date().addingTimeInterval(60)
        XCTAssertTrue(s.isPaused())
        s.excludedSites = ["Bank.com", "bank.com"]
        XCTAssertEqual(s.excludedSites, ["bank.com"])
        XCTAssertTrue(s.rules.isExcludedSite("https://www.bank.com"))
    }
}
