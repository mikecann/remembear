import Foundation

/// Which Claude login (`CLAUDE_CONFIG_DIR`) a summary runs on. The main one
/// first, then the fallbacks in order. A login that answers "you've hit your
/// limit" (or is rate limited or signed out) rests for a while, so one login
/// running dry stops summaries for a minute at most instead of until its
/// weekly reset (12 Nov 2026: the default login ran out and summaries stopped
/// for 19 hours).
public struct ClaudeLogins: Sendable {
    /// nil is the default login (~/.claude).
    public private(set) var order: [String?] = []
    private var blockedUntil: [String: Date] = [:]

    /// How long a login with a problem is left alone before it's tried
    /// again. Short enough to notice a 5-hour reset, long enough not to spend
    /// a call on it every pass.
    public static let backoff: TimeInterval = 60 * 60

    public init(main: String?, fallbacks: [String]) {
        configure(main: main, fallbacks: fallbacks)
    }

    /// Rereads the settings (each pass, so a `defaults write` applies without
    /// a restart), keeping any rest a login is already on.
    public mutating func configure(main: String?, fallbacks: [String]) {
        var seen = Set<String>()
        order = ([main] + fallbacks.map { Optional($0) }).filter { seen.insert($0 ?? "").inserted }
    }

    /// Logins to try now, best first. Empty when every one is resting: the
    /// caller fails the window without launching anything, and it's retried
    /// on its usual schedule.
    public func candidates(now: Date) -> [String?] {
        order.filter { (blockedUntil[$0 ?? ""] ?? .distantPast) <= now }
    }

    public mutating func rest(_ login: String?, now: Date) {
        blockedUntil[login ?? ""] = now.addingTimeInterval(Self.backoff)
    }

    public mutating func succeeded(_ login: String?) {
        blockedUntil[login ?? ""] = nil
    }

    /// A failure that's about the login rather than the prompt or Claude as
    /// a whole, so another login may well work: out of usage ("You've hit
    /// your weekly limit · resets ...", "Claude AI usage limit reached|<epoch>"),
    /// rate limited, or signed out. Overloaded and timeouts aren't: another
    /// login wouldn't help.
    public static func isLoginProblem(_ message: String) -> Bool {
        let m = message.lowercased()
        let signals = ["usage limit", "rate limit", "rate_limit", "not logged in", "please run /login", "invalid api key",
                       "authentication_error", "oauth token has expired", "credit balance is too low"]
        return (m.contains("hit your") && m.contains("limit")) || signals.contains { m.contains($0) }
    }

    /// Screen history must never go through a work account (Mike's Convex
    /// login), whatever the settings say. Takes the login's own record of
    /// which account it is; a login that can't say who it is isn't used.
    public static func isPersonalAccount(email: String?) -> Bool {
        guard let email = email?.lowercased(), email.contains("@") else { return false }
        return !email.hasSuffix("@convex.dev")
    }
}
