import XCTest
@testable import RememBearCore

final class RecordingHealthTests: XCTestCase {
    // 3 Nov 2026: windows changed all day and nothing was recorded.
    func testSwitchingWindowsWithNothingRecordedIsReportedOnce() {
        var h = RecordingHealth(quietFor: 900, minChanges: 3)
        h.settled(uptime: 0)
        for (i, key) in ["a", "b", "c", "a"].enumerated() { h.noteFront(key, uptime: Double(i) * 100) }
        XCTAssertNil(h.check(uptime: 899))
        XCTAssertEqual(h.check(uptime: 900), .notRecording)
        XCTAssertNil(h.check(uptime: 2000))
        // Recording again, then quiet again: reported again.
        h.settled(uptime: 2000)
        for key in ["b", "c", "a"] { h.noteFront(key, uptime: 2100) }
        XCTAssertEqual(h.check(uptime: 2900), .notRecording)
    }

    func testSittingInOneWindowIsFine() {
        var h = RecordingHealth(quietFor: 900, minChanges: 3)
        h.settled(uptime: 0)
        for t in stride(from: 0.0, to: 5000, by: 2) { h.noteFront("a", uptime: t) }
        XCTAssertNil(h.check(uptime: 5000))
    }

    func testWindowsThatSettleAreFine() {
        var h = RecordingHealth(quietFor: 900, minChanges: 3)
        for (i, key) in ["a", "b", "c", "d", "e"].enumerated() {
            h.noteFront(key, uptime: Double(i) * 300)
            h.settled(uptime: Double(i) * 300 + 4)
        }
        XCTAssertNil(h.check(uptime: 1300))
    }

    func testTheClockStartsAtTheFirstWindowSeen() {
        var h = RecordingHealth(quietFor: 900, minChanges: 3)
        for key in ["a", "b", "c"] { h.noteFront(key, uptime: 5000) }
        XCTAssertNil(h.check(uptime: 5899))
        XCTAssertEqual(h.check(uptime: 5900), .notRecording)
    }
}

final class SentryReportTests: XCTestCase {
    let dsn = "https://abc123@o1.ingest.us.sentry.io/456"

    func testBuildsAnEnvelopeForTheProject() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let r = try XCTUnwrap(SentryReport(dsn: dsn, problem: .readStuck, release: "remembear@0.1.0+1", os: "27.2",
                                           at: Date(timeIntervalSince1970: 100), eventID: id))
        XCTAssertEqual(r.url.absoluteString, "https://o1.ingest.us.sentry.io/api/456/envelope/")
        XCTAssertTrue(r.auth.contains("sentry_key=abc123"))
        let lines = String(decoding: r.body, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [String: Any])
        XCTAssertEqual(event["event_id"] as? String, "11111111222233334444555555555555")
        XCTAssertEqual(event["environment"] as? String, "production")
        XCTAssertEqual(event["fingerprint"] as? [String], ["read-stuck"])
        XCTAssertEqual((event["message"] as? [String: String])?["formatted"], Problem.readStuck.message)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(header["length"] as? Int, lines[2].utf8.count)
    }

    // Privacy: the only words that go are the fixed message.
    func testNothingButTheFixedFieldsGoes() throws {
        let r = try XCTUnwrap(SentryReport(dsn: dsn, problem: .notRecording, release: "r", os: "27.2", at: Date()))
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(decoding: r.body, as: UTF8.self).split(separator: "\n")[2].utf8)) as? [String: Any])
        XCTAssertEqual(Set(event.keys), ["event_id", "timestamp", "platform", "level", "logger", "environment", "release",
                                         "message", "fingerprint", "tags", "contexts"])
    }

    func testABadDSNIsNil() {
        XCTAssertNil(SentryReport(dsn: "nope", problem: .readStuck, release: "r", os: "1", at: Date()))
        XCTAssertNil(SentryReport(dsn: "https://o1.ingest.us.sentry.io/456", problem: .readStuck, release: "r", os: "1", at: Date()))
    }
}
