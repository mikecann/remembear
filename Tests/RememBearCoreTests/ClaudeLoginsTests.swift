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

    // 14 Nov 2026: Claude Code sign-ins now end after about 28 days, and the
    // default login's "time limit" error didn't move summaries to the other
    // logins, so none were written for 11 days and unsummarised days aged out.
    func testASignInThatHasEndedIsALoginProblem() {
        XCTAssertTrue(ClaudeLogins.isLoginProblem("claude error: Failed to authenticate: this login reached its time limit and cannot be renewed. Run `claude auth login` to sign in again, or use `claude setup-token` and set CLAUDE_CODE_OAUTH_TOKEN for unattended jobs"))
        XCTAssertTrue(ClaudeLogins.isLoginProblem("claude error: Failed to authenticate. API Error: 401"))
        XCTAssertTrue(ClaudeLogins.isLoginProblem("claude error: API Error: 401 OAuth token has been revoked"))
        // A request that ran out of time isn't the login's fault.
        XCTAssertFalse(ClaudeLogins.isLoginProblem("claude error: the request reached its time limit"))
    }

    // Threadbear keeps a login's year-long `claude setup-token` token in
    // threadbear-token.json in the login's folder.
    func testReadsAYearLongToken() {
        XCTAssertEqual(ClaudeLogins.yearToken(Data(#"{"madeAt":"2026-11-17T23:38:54Z","token":"sk-ant-oat01-abc"}"#.utf8)), "sk-ant-oat01-abc")
        XCTAssertNil(ClaudeLogins.yearToken(Data(#"{"madeAt":"2026-11-17T23:38:54Z"}"#.utf8)))
        XCTAssertNil(ClaudeLogins.yearToken(Data(#"{"token":"  "}"#.utf8)))
        // A token broken over lines can't go in a header, and the error that
        // gives wouldn't move summaries to another login.
        XCTAssertNil(ClaudeLogins.yearToken(Data(#"{"token":"sk-ant-oat01-abc\ndef"}"#.utf8)))
        XCTAssertNil(ClaudeLogins.yearToken(Data(#"{"token":"sk-ant oat01"}"#.utf8)))
        XCTAssertNil(ClaudeLogins.yearToken(Data("not json".utf8)))
        XCTAssertNil(ClaudeLogins.yearToken(nil))
    }
}
