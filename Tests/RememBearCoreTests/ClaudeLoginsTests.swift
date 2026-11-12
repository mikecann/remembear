import XCTest
@testable import RememBearCore

final class ClaudeLoginsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMainFirstThenFallbacksWithoutDuplicates() {
        let l = ClaudeLogins(main: nil, fallbacks: ["/a", "/b", "/a"])
        XCTAssertEqual(l.candidates(now: now), [nil, "/a", "/b"])
    }

    func testRestingLoginIsSkippedForAnHour() {
        var l = ClaudeLogins(main: nil, fallbacks: ["/a", "/b"])
        l.rest(nil, now: now)
        XCTAssertEqual(l.candidates(now: now), ["/a", "/b"])
        XCTAssertEqual(l.candidates(now: now.addingTimeInterval(ClaudeLogins.backoff + 1)), [nil, "/a", "/b"])
        l.succeeded(nil)
        XCTAssertEqual(l.candidates(now: now), [nil, "/a", "/b"])
    }

    func testAllRestingLaunchesNothing() {
        var l = ClaudeLogins(main: "/m", fallbacks: ["/a"])
        l.rest("/m", now: now)
        l.rest("/a", now: now)
        XCTAssertEqual(l.candidates(now: now), [])
    }

    func testReconfiguringKeepsRests() {
        var l = ClaudeLogins(main: nil, fallbacks: ["/a"])
        l.rest("/a", now: now)
        l.configure(main: nil, fallbacks: ["/a", "/b"])
        XCTAssertEqual(l.candidates(now: now), [nil, "/b"])
    }

    func testRecognisesLoginProblems() {
        XCTAssertTrue(ClaudeLogins.isLoginProblem("claude error: You've hit your weekly limit · resets Nov 18 at 5am (Australia/Perth)"))
        XCTAssertTrue(ClaudeLogins.isLoginProblem("claude error: You've hit your session limit · resets 3pm"))
        XCTAssertTrue(ClaudeLogins.isLoginProblem("Claude AI usage limit reached|1800000000"))
        XCTAssertTrue(ClaudeLogins.isLoginProblem("claude error: API Error: 429 Rate limit reached"))
        XCTAssertTrue(ClaudeLogins.isLoginProblem("claude error: Invalid API key · Please run /login"))
        XCTAssertFalse(ClaudeLogins.isLoginProblem("claude returned no result"))
        XCTAssertFalse(ClaudeLogins.isLoginProblem("claude error: API Error: 529 Overloaded"))
        XCTAssertFalse(ClaudeLogins.isLoginProblem("claude exited 15 without JSON: "))
    }

    func testWorkAccountsAreRefused() {
        XCTAssertFalse(ClaudeLogins.isPersonalAccount(email: "someone@Convex.dev"))
        XCTAssertTrue(ClaudeLogins.isPersonalAccount(email: "someone@gmail.com"))
        XCTAssertFalse(ClaudeLogins.isPersonalAccount(email: nil))
        XCTAssertFalse(ClaudeLogins.isPersonalAccount(email: ""))
    }
}
