import XCTest
@testable import RememBearCore

final class PrivacyTests: XCTestCase {
    let rules = PrivacyRules(excludedApps: ["com.example.bank"], excludedSites: ["bank.com", ".Health.gov."])

    func testPrivateBrowserWindowsAreNeverRecorded() {
        // Titles as macOS reports them, checked by hand on 29 Oct 2026.
        XCTAssertFalse(rules.allows(bundleID: "com.google.Chrome", windowTitle: "about:blank - Google Chrome (Incognito)", url: nil))
        XCTAssertFalse(rules.allows(bundleID: "net.imput.helium", windowTitle: "about:blank - Helium (Incognito)", url: nil))
        XCTAssertFalse(rules.allows(bundleID: "com.apple.Safari", windowTitle: "Example Domain, Private Browsing", url: "https://example.com"))
        XCTAssertFalse(rules.allows(bundleID: "org.mozilla.firefox", windowTitle: "Example — Mozilla Firefox Private Browsing", url: nil))
        XCTAssertFalse(rules.allows(bundleID: "com.microsoft.edgemac", windowTitle: "Example - [InPrivate] - Microsoft Edge", url: nil))
        XCTAssertFalse(rules.allows(bundleID: "com.brave.Browser", windowTitle: "Example - Brave (Private)", url: nil))
    }

    func testNormalBrowserWindowsAreRecorded() {
        XCTAssertTrue(rules.allows(bundleID: "com.google.Chrome", windowTitle: "Notifications / X - Google Chrome – Michael", url: "https://x.com/notifications"))
        XCTAssertTrue(rules.allows(bundleID: "com.apple.Safari", windowTitle: "Start Page", url: nil))
    }

    func testBrowserWindowWithoutATitleIsTreatedAsPrivate() {
        XCTAssertFalse(rules.allows(bundleID: "com.google.Chrome", windowTitle: nil, url: nil))
        XCTAssertFalse(rules.allows(bundleID: "com.google.Chrome", windowTitle: "  ", url: nil))
        // Other apps often have untitled windows, and that's fine.
        XCTAssertTrue(rules.allows(bundleID: "com.apple.finder", windowTitle: nil, url: nil))
    }

    func testExcludedAppsIncludingPasswordManagers() {
        XCTAssertFalse(rules.allows(bundleID: "com.example.bank", windowTitle: "Accounts", url: nil))
        XCTAssertFalse(rules.allows(bundleID: "com.1password.1password", windowTitle: "1Password", url: nil))
        XCTAssertFalse(PrivacyRules().allows(bundleID: "com.apple.loginwindow", windowTitle: nil, url: nil))
    }

    func testExcludedSitesCoverSubdomainsOnly() {
        XCTAssertFalse(rules.allows(bundleID: "com.google.Chrome", windowTitle: "Bank", url: "https://bank.com/"))
        XCTAssertFalse(rules.allows(bundleID: "com.google.Chrome", windowTitle: "Bank", url: "https://login.bank.com/x"))
        XCTAssertFalse(rules.allows(bundleID: "com.google.Chrome", windowTitle: "Health", url: "https://my.health.gov/"))
        XCTAssertTrue(rules.allows(bundleID: "com.google.Chrome", windowTitle: "Not a bank", url: "https://notbank.com/"))
    }

    func testSecureAndSecretLookingFieldValuesAreDropped() {
        XCTAssertNil(Privacy.safeValue("hunter2", role: "AXTextField", subrole: "AXSecureTextField", labels: []))
        XCTAssertNil(Privacy.safeValue("123456", role: "AXTextField", subrole: nil, labels: ["One-time code"]))
        XCTAssertNil(Privacy.safeValue("abc", role: "AXTextField", subrole: nil, labels: [nil, "API key"]))
        XCTAssertEqual(Privacy.safeValue("ship it", role: "AXTextArea", subrole: nil, labels: ["Message #general"]), "ship it")
    }

    func testRedactsKeysButKeepsPathsAndHashes() {
        XCTAssertEqual(Privacy.redactSecrets("key sk-proj-abcdefghijklmnop1234 here"), "key [redacted] here")
        XCTAssertEqual(Privacy.redactSecrets("card 4111 1111 1111 1111 ok"), "card [redacted] ok")
        XCTAssertEqual(Privacy.redactSecrets("token Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4z0AbC"), "token [redacted]")
        let path = "/Users/m5-mike/dev/me/mikerosoft-tools/remembear/Sources/RememBearCore/Privacy.swift"
        XCTAssertEqual(Privacy.redactSecrets(path), path)
        let sha = "commit 3f9a2b7c1d4e5f60718293a4b5c6d7e8f9012345"
        XCTAssertEqual(Privacy.redactSecrets(sha), sha)
        let slug = "2026-10-29T06-20-00-WgFr-10min-memory-summary-and-more"
        XCTAssertEqual(Privacy.redactSecrets(slug), slug)
    }
}
