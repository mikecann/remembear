import XCTest
@testable import RememBearCore

/// Recording reads screenshots now, which see everything on screen, and
/// window titles from the window list, which don't say whether a browser
/// window is private.
final class ScreenshotPrivacyTests: XCTestCase {
    let rules = PrivacyRules(excludedSites: ["bank.com"])

    func testOnlyNormalChromiumWindowsAreRecorded() {
        let normal = BrowserWindow(mode: "normal", title: "Pull Request #59871 · convex/convex", url: "https://github.com/convex/convex/pull/59871")
        XCTAssertTrue(rules.allowsBrowser(bundleID: "com.google.Chrome", windowListTitle: "Pull Request #59871 · convex/convex", script: normal))
        // The window list titles an incognito window like any other.
        let incognito = BrowserWindow(mode: "incognito", title: "New Incognito tab", url: "chrome://newtab/")
        XCTAssertFalse(rules.allowsBrowser(bundleID: "com.google.Chrome", windowListTitle: "New Incognito tab", script: incognito))
    }

    func testWhenInDoubtABrowserWindowIsLeftOut() {
        let normal = BrowserWindow(mode: "normal", title: "Inbox", url: "https://mail.google.com/")
        // AppleScript wasn't allowed, or didn't answer.
        XCTAssertFalse(rules.allowsBrowser(bundleID: "com.google.Chrome", windowListTitle: "Inbox", script: nil))
        // AppleScript described a different window than the one in front.
        XCTAssertFalse(rules.allowsBrowser(bundleID: "com.google.Chrome", windowListTitle: "Something else", script: normal))
        XCTAssertFalse(rules.allowsBrowser(bundleID: "com.google.Chrome", windowListTitle: nil, script: normal))
        // Safari and Firefox can't say whether a window is private.
        XCTAssertFalse(rules.allowsBrowser(bundleID: "com.apple.Safari", windowListTitle: "Inbox", script: normal))
        XCTAssertFalse(rules.allowsBrowser(bundleID: "org.mozilla.firefox", windowListTitle: "Inbox", script: normal))
    }

    func testExcludedSitesStillApplyToBrowsers() {
        let bank = BrowserWindow(mode: "normal", title: "Accounts", url: "https://login.bank.com/")
        XCTAssertFalse(rules.allowsBrowser(bundleID: "com.google.Chrome", windowListTitle: "Accounts", script: bank))
    }

    func testPasswordManagersAndSystemPromptsAreExcluded() {
        for id in ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.Passwords", "com.apple.SecurityAgent", "org.keepassxc.keepassxc"] {
            XCTAssertFalse(rules.allows(bundleID: id, windowTitle: "x", url: nil), id)
        }
    }

    func testEnvironmentVariableValuesAreMasked() {
        XCTAssertEqual(Privacy.redactScreenText("CONVEX_DEPLOYMENT=dev:happy-animal-123"), "CONVEX_DEPLOYMENT=[redacted]")
        XCTAssertEqual(Privacy.redactScreenText("export OPENAI_API_KEY=\"sk-short\""), "export OPENAI_API_KEY=[redacted]")
        XCTAssertEqual(Privacy.redactScreenText("$ STRIPE_KEY=abc123 node server.js"), "$ STRIPE_KEY=[redacted] node server.js")
        XCTAssertEqual(Privacy.redactScreenText("DATABASE_URL: postgres://u:p@db/x"), "DATABASE_URL: [redacted]")
        XCTAssertEqual(Privacy.redactScreenText("  \"RESEND_API_KEY\": \"re_123\","), "  \"RESEND_API_KEY\": [redacted]")
        // A dashboard's list, read as name, gap, value.
        XCTAssertEqual(Privacy.redactScreenText("AUTH_SECRET  hunter2hunter2"), "AUTH_SECRET  [redacted]")
    }

    func testSecretsLabelledAsSuchAreMasked() {
        XCTAssertEqual(Privacy.redactScreenText("password: hunter2"), "password: [redacted]")
        XCTAssertEqual(Privacy.redactScreenText("api_key = 'abc'"), "api_key = [redacted]")
        XCTAssertEqual(Privacy.redactScreenText("Authorization: Bearer abcdefgh12345"), "Authorization: Bearer [redacted]")
        XCTAssertEqual(Privacy.redactScreenText("git clone https://mike:ghtok123@github.com/x"), "git clone https://mike:[redacted]@github.com/x")
        XCTAssertEqual(Privacy.redactScreenText("key prod:happy-animal-123|eyJ2MjoiYWJjZGVmZ2hpams"), "key [redacted]")
        XCTAssertEqual(Privacy.redactScreenText("AIzaSyA1b2C3d4E5f6G7h8I9j0KlMnOpQrStUvW"), "[redacted]")
    }

    func testPrivateKeyBlocksAndBase64BodiesAreMasked() {
        let pem = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\nabc\n-----END PRIVATE KEY-----\nafter"
        XCTAssertEqual(Privacy.redactScreenText(pem), "[redacted private key]\nafter")
        XCTAssertEqual(Privacy.redactScreenText("MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQ"), "[redacted]")
    }

    func testOrdinaryScreenTextSurvives() {
        let text = """
        Projects  69 projects
        NOTE: the build is green
        commit 3f9a2b7c1d4e5f60718293a4b5c6d7e8f9012345
        /Users/m5-mike/dev/me/threadbear/app/Sources/Threadbear/Views/ProjectsHome.swift
        Mike: ship it when the tests pass
        """
        XCTAssertEqual(Privacy.redactScreenText(text), text)
    }

    func testRecognizedTextBecomesRowsTopToBottom() {
        let pieces = [
            RecognizedText(text: "value-two", x: 0.5, y: 0.205, width: 0.2, height: 0.03),
            RecognizedText(text: "Title", x: 0.1, y: 0.05, width: 0.3, height: 0.04),
            RecognizedText(text: "NAME_TWO", x: 0.1, y: 0.2, width: 0.2, height: 0.03),
            RecognizedText(text: "NAME_ONE", x: 0.1, y: 0.15, width: 0.2, height: 0.03),
            RecognizedText(text: "value-one", x: 0.5, y: 0.152, width: 0.2, height: 0.03),
            RecognizedText(text: "  ", x: 0.1, y: 0.9, width: 0.1, height: 0.03),
        ]
        XCTAssertEqual(ScreenText.lines(pieces), ["Title", "NAME_ONE  value-one", "NAME_TWO  value-two"])
        XCTAssertEqual(Privacy.redactScreenText(ScreenText.lines(pieces).joined(separator: "\n")), "Title\nNAME_ONE  [redacted]\nNAME_TWO  [redacted]")
    }

    func testKeyPagesAreNeverCaptured() {
        for url in ["https://platform.openai.com/api-keys", "https://github.com/settings/tokens/new", "https://console.cloud.google.com/apis/credentials?project=x",
                    "https://dash.cloudflare.com/profile/api-tokens", "https://vercel.com/mike/app/settings/environment-variables",
                    "https://dashboard.convex.dev/t/mike/poddle/happy-animal-123/settings/environment-variables", "https://resend.com/api-keys",
                    "https://console.anthropic.com/settings/keys", "https://github.com/mikecann/poddle/settings/secrets/actions"] {
            XCTAssertTrue(Privacy.isKeyPage(url: url), url)
            let w = BrowserWindow(mode: "normal", title: "Keys", url: url)
            XCTAssertFalse(rules.allowsBrowser(bundleID: "com.google.Chrome", windowListTitle: "Keys", script: w), url)
        }
        for url in ["https://github.com/convex/convex/pull/59871", "https://x.com/notifications", "https://dashboard.convex.dev/t/mike/poddle/happy-animal-123/data"] {
            XCTAssertFalse(Privacy.isKeyPage(url: url), url)
        }
    }

    func testAKeyBeingShownDropsTheWholeCapture() {
        XCTAssertTrue(Privacy.looksLikeKeyBeingShown("Save your key\nPlease save this secret key somewhere safe. You won't be able to view it again."))
        XCTAssertTrue(Privacy.looksLikeKeyBeingShown("Make sure to copy your personal access token now."))
        XCTAssertTrue(Privacy.looksLikeKeyBeingShown("API key created"))
        XCTAssertTrue(Privacy.looksLikeKeyBeingShown("Client secret  Copy"))
        XCTAssertFalse(Privacy.looksLikeKeyBeingShown("Mike: ship it when the tests pass\nProjects  69 projects"))
    }
}
