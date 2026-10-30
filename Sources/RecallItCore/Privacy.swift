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
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
        "me.proton.pass.electron", "com.yubico.yubioath", "com.yubico.authenticator",
        // macOS's own password and Touch ID prompts, when they come to the front.
        "com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent", "com.apple.coreservices.uiagent",
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

/// What a browser said over AppleScript about its front window.
public struct BrowserWindow: Equatable, Sendable {
    /// Chromium's window mode: "normal" or "incognito".
    public var mode: String?
    public var title: String?
    public var url: String?

    public init(mode: String?, title: String?, url: String?) {
        self.mode = mode
        self.title = title
        self.url = url
    }
}

extension PrivacyRules {
    /// Whether a browser's front window may be recorded, when its title came
    /// from the window list rather than the Accessibility API. The window
    /// list only has the page's title: a Chrome incognito window showing
    /// "New Incognito tab" said nothing else (checked 30 Oct 2026). So only
    /// Chromium browsers that answer AppleScript can be recorded, and only
    /// when the front window's mode is "normal" and its title matches the
    /// window list's, so both describe the same window. Safari and Firefox
    /// can't say whether a window is private, so nothing from them is kept.
    public func allowsBrowser(bundleID: String, windowListTitle: String?, script: BrowserWindow?) -> Bool {
        guard Privacy.isChromium(bundleID), let script, script.mode == "normal" else { return false }
        guard let listed = windowListTitle?.trimmingCharacters(in: .whitespaces), !listed.isEmpty,
              script.title?.trimmingCharacters(in: .whitespaces) == listed else { return false }
        return allows(bundleID: bundleID, windowTitle: listed, url: script.url)
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
        browserIDs.contains(bundleID) || isChromium(bundleID)
    }

    public static func isChromium(_ bundleID: String) -> Bool {
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
        pattern: #"\b(sk-[A-Za-z0-9_-]{16,}|[sr]k_(?:live|test)_[A-Za-z0-9]{10,}|AIza[0-9A-Za-z_-]{30,}|ya29\.[0-9A-Za-z_-]{20,}|glpat-[0-9A-Za-z_-]{16,}|npm_[A-Za-z0-9]{30,}|hf_[A-Za-z0-9]{30,}|xapp-[A-Za-z0-9-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|[A-Za-z0-9+_-]{32,})\b|\b\d(?:[ -]?\d){12,18}\b"#)

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
        let known = ["sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "AIza", "ya29.", "glpat-", "npm_", "hf_", "xapp-",
                     "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "xoxa-", "xoxb-", "xoxp-", "xoxr-", "AKIA", "eyJ"]
        if known.contains(where: s.hasPrefix) { return true }
        let digitsOnly = s.allSatisfy { $0.isNumber || $0 == " " || $0 == "-" }
        if digitsOnly { return true }
        // File names and slugs are long too, but split into short words on
        // dashes and underscores. A key is one long mixed-case run.
        return s.split(whereSeparator: { $0 == "-" || $0 == "_" }).contains { piece in
            piece.count >= 24 && piece.contains(where: \.isUppercase) && piece.contains(where: \.isLowercase) && piece.contains(where: \.isNumber)
        }
    }

    // MARK: Text read off the screen

    // Environment variables: FOO_BAR=value anywhere on a line (a shell, a
    // .env file, a command), and FOO_BAR: value or "FOO_BAR": value at the
    // start of one (YAML, JSON, a dashboard's list).
    private static let envAssignment = try! NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9]*_[A-Z0-9_]+)=("[^"\n]*"|'[^'\n]*'|[^\s]+)"#)
    private static let envKeyValue = try! NSRegularExpression(
        pattern: #"^(\s*["']?[A-Z][A-Z0-9]*_[A-Z0-9_]+["']?\s*:\s*)(\S.*)$"#, options: .anchorsMatchLines)
    // A dashboard's table read as a row: the name, a gap, then the value.
    private static let envTableRow = try! NSRegularExpression(
        pattern: #"^(\s*[A-Z][A-Z0-9]*_[A-Z0-9_]+(?:\s{2,}|\t))(\S.*)$"#, options: .anchorsMatchLines)
    // Anything labelled like a secret: "password: hunter2", api_key = "…".
    private static let labelledSecret = try! NSRegularExpression(
        pattern: #"(?i)\b(pass(?:word|wd|code|phrase)?|pwd|secret|client[_ -]?secret|token|api[_ -]?key|access[_ -]?key|private[_ -]?key|auth[_ -]?key)(["']?\s*[:=]\s*)("[^"\n]*"|'[^'\n]*'|[^\s,;]+)"#)
    private static let urlCredentials = try! NSRegularExpression(pattern: #"(\b[a-z][a-z0-9+.-]*://[^\s:/@]+:)[^\s@/]+@"#, options: .caseInsensitive)
    private static let authHeader = try! NSRegularExpression(pattern: #"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#)
    // Convex deploy keys, e.g. "prod:happy-animal-123|eyJ...".
    private static let deployKey = try! NSRegularExpression(pattern: #"\b(?:prod|dev|preview|project):[A-Za-z0-9-]+\|[A-Za-z0-9+/=_-]{16,}"#)
    private static let privateKeyBlock = try! NSRegularExpression(
        pattern: #"-{3,}\s*BEGIN[A-Z ]*PRIVATE KEY\s*-{3,}[\s\S]*?(?:-{3,}\s*END[A-Z ]*PRIVATE KEY\s*-{3,}|$)"#)

    /// Text read off a screenshot, with secrets masked: environment variable
    /// values (all of them, not only the ones that look secret), anything
    /// labelled as a password, token or key, credentials in URLs and auth
    /// headers, private key blocks and long base64 lines, then the token
    /// shapes `redactSecrets` knows. A screenshot sees everything on screen,
    /// so this errs towards masking too much.
    public static func redactScreenText(_ text: String) -> String {
        var t = replace(privateKeyBlock, in: text, with: "[redacted private key]")
        t = replace(deployKey, in: t, with: "[redacted]")
        t = replace(urlCredentials, in: t, with: "$1[redacted]@")
        t = replace(authHeader, in: t, with: "$1 [redacted]")
        t = replace(envAssignment, in: t, with: "$1=[redacted]")
        t = replace(envKeyValue, in: t, with: "$1[redacted]")
        t = replace(envTableRow, in: t, with: "$1[redacted]")
        t = replace(labelledSecret, in: t, with: "$1$2[redacted]")
        t = t.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            isBase64Line(line) ? "[redacted]" : String(line)
        }.joined(separator: "\n")
        return redactSecrets(t)
    }

    private static func replace(_ re: NSRegularExpression, in text: String, with template: String) -> String {
        re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
            .replacingOccurrences(of: "[redacted][redacted]", with: "[redacted]")
    }

    // A line of nothing but base64, as in a key or certificate body. Hex
    // (git hashes) has no upper case, so it's left alone.
    private static func isBase64Line<S: StringProtocol>(_ line: S) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.count >= 40, s != "[redacted]" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/="))
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else { return false }
        return s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase) && s.contains(where: \.isNumber)
    }
}
