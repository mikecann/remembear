import Foundation

/// Decides what may be recorded. Everything is checked before any window text
/// is read, so excluded apps, sites and private windows never reach the disk.
public struct PrivacyRules: Equatable, Sendable {
    public var excludedApps: Set<String>
    /// Hosts, matched on the host and every subdomain: "bank.com" also covers
    /// "www.bank.com" and "login.bank.com".
    public var excludedSites: [String]

    /// Password managers are always excluded, on top of the user's own list.
    public static let alwaysExcludedApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.bitwarden.desktop",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        // The lock screen and screen saver.
        "com.apple.loginwindow", "com.apple.ScreenSaver.Engine",
    ]

    public init(excludedApps: Set<String> = [], excludedSites: [String] = []) {
        self.excludedApps = excludedApps
        self.excludedSites = excludedSites
    }

    public func isExcludedApp(_ bundleID: String) -> Bool {
        Self.alwaysExcludedApps.contains(bundleID) || excludedApps.contains(bundleID)
    }

    public func isExcludedSite(_ url: String?) -> Bool {
        guard let host = Privacy.host(of: url) else { return false }
        return excludedSites.contains { site in
            let s = site.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return !s.isEmpty && (host == s || host.hasSuffix("." + s))
        }
    }

    /// Whether anything from this window may be recorded. Browsers are checked
    /// for private windows from the window title, and a browser window whose
    /// title can't be read is treated as private: when in doubt, leave it out.
    public func allows(bundleID: String, windowTitle: String?, url: String?) -> Bool {
        if isExcludedApp(bundleID) { return false }
        if Privacy.isBrowser(bundleID) {
            guard let title = windowTitle, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            if Privacy.isPrivateWindowTitle(title) { return false }
        }
        return !isExcludedSite(url)
    }
}

public enum Privacy {
    private static let browserIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "app.zen-browser.zen", "com.kagi.kagimacOS",
    ]

    /// Chromium browsers are matched by name, as there are a lot of them and
    /// they all mark private windows the same way.
    private static let chromiumHints = ["chrome", "chromium", "brave", "edgemac", "thebrowser", "helium", "vivaldi", "opera"]

    public static func isBrowser(_ bundleID: String) -> Bool {
        if browserIDs.contains(bundleID) { return true }
        let id = bundleID.lowercased()
        return chromiumHints.contains { id.contains($0) }
    }

    // Checked on the macOS accessibility title of the window, as seen on
    // 29 Oct 2026:
    //   Chrome, Helium and other Chromium browsers: "about:blank - Google Chrome (Incognito)"
    //   Safari: "Example Domain, Private Browsing"
    //   Firefox: "… — Mozilla Firefox Private Browsing"
    //   Edge: "… - [InPrivate] - Microsoft Edge"; Brave: "… (Private)"
    private static let privateTitle = try! NSRegularExpression(
        pattern: #"\((incognito|private|inprivate)\)|private browsing|\binprivate\b|\bincognito\b"#,
        options: .caseInsensitive)

    public static func isPrivateWindowTitle(_ title: String) -> Bool {
        privateTitle.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    public static func host(of url: String?) -> String? {
        guard let url, let components = URLComponents(string: url), let host = components.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    // Field labels that suggest the value is a secret, as in Mitts and Paws.
    private static let secretName = try! NSRegularExpression(
        pattern: #"pass(word|code|phrase)?|secret|token|api.?key|cvc|cvv|card.?number|one.?time|otp|\bpin\b|security code|2fa|mfa"#,
        options: .caseInsensitive)

    public static func looksSecret(_ s: String) -> Bool {
        secretName.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// A text field's value, or nil when it must not be recorded: secure
    /// fields, fields labelled like secrets, and values that look like keys.
    public static func safeValue(_ value: String?, role: String?, subrole: String?, labels: [String?]) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if subrole == "AXSecureTextField" || role == "AXSecureTextField" { return nil }
        if labels.contains(where: { $0.map(looksSecret) ?? false }) { return nil }
        return redactSecrets(value)
    }

    // Well-known token shapes, long unbroken runs of key-like characters, and
    // card-number-like digit runs.
    private static let secretValue = try! NSRegularExpression(
        pattern: #"\b(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|[A-Za-z0-9+_-]{32,})\b|\b\d(?:[ -]?\d){12,18}\b"#)

    /// Masks API keys, tokens and card numbers inside text. Long runs are only
    /// masked when they mix upper case, lower case and digits, so git hashes,
    /// UUID-ish ids and long-file-names-with-dashes survive.
    public static func redactSecrets(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in secretValue.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let candidate = ns.substring(with: m.range)
            if !isSecretLooking(candidate) { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + "[redacted]"
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    private static func isSecretLooking(_ s: String) -> Bool {
        let known = ["sk-", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "xoxa-", "xoxb-", "xoxp-", "xoxr-", "AKIA", "eyJ"]
        if known.contains(where: s.hasPrefix) { return true }
        let digitsOnly = s.allSatisfy { $0.isNumber || $0 == " " || $0 == "-" }
        if digitsOnly { return true }
        // File names and slugs are long too, but split into short words on
        // dashes and underscores. A key is one long mixed-case run.
        return s.split(whereSeparator: { $0 == "-" || $0 == "_" }).contains { piece in
            piece.count >= 24 && piece.contains(where: \.isUppercase) && piece.contains(where: \.isLowercase) && piece.contains(where: \.isNumber)
        }
    }
}
