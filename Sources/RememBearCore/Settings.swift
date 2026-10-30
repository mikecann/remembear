import Foundation

/// UserDefaults for app.mikecann.remembear. No settings window: the menu
/// covers pausing and excluding, and `defaults write` covers the rest.
public final class Settings: @unchecked Sendable {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var excludedApps: [String] {
        get { defaults.stringArray(forKey: "excludedApps") ?? [] }
        set { defaults.set(Array(Set(newValue)).sorted(), forKey: "excludedApps") }
    }

    public var excludedSites: [String] {
        get { defaults.stringArray(forKey: "excludedSites") ?? [] }
        set { defaults.set(Array(Set(newValue.map { $0.lowercased() })).sorted(), forKey: "excludedSites") }
    }

    public var rules: PrivacyRules {
        PrivacyRules(excludedApps: Set(excludedApps), excludedSites: excludedSites)
    }

    /// Model aliases for `claude --model`. Haiku keeps the 144 daily
    /// 10-minute calls light on the subscription; the four rollups get Sonnet.
    public var tenMinuteModel: String {
        get { defaults.string(forKey: "tenMinuteModel") ?? "haiku" }
        set { defaults.set(newValue, forKey: "tenMinuteModel") }
    }

    public var sixHourModel: String {
        get { defaults.string(forKey: "sixHourModel") ?? "sonnet" }
        set { defaults.set(newValue, forKey: "sixHourModel") }
    }

    /// Defaults to ~/.local/bin/claude, where Claude Code's installer puts it.
    public var claudePath: String {
        get { defaults.string(forKey: "claudePath") ?? NSHomeDirectory() + "/.local/bin/claude" }
        set { defaults.set(newValue, forKey: "claudePath") }
    }

    /// Which Claude login to use (CLAUDE_CONFIG_DIR). Unset means ~/.claude.
    public var claudeConfigDir: String? {
        get { defaults.string(forKey: "claudeConfigDir") }
        set { defaults.set(newValue, forKey: "claudeConfigDir") }
    }

    public var pausedUntil: Date? {
        get { defaults.object(forKey: "pausedUntil") as? Date }
        set { defaults.set(newValue, forKey: "pausedUntil") }
    }

    public func isPaused(at now: Date = Date()) -> Bool {
        guard let until = pausedUntil else { return false }
        return until > now
    }
}
