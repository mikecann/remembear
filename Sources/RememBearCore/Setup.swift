import Foundation

/// Where one of RememBear's permissions stands, for the setup window.
public enum PermissionState: Equatable, Sendable {
    case granted
    /// Not asked yet, or not switched on yet.
    case missing
    /// Mike said no; only System Settings can turn it on now.
    case denied
    /// Chrome isn't running, so macOS can't say. It asks once Chrome is open.
    case waitingForApp
    /// Chrome isn't installed, so there's nothing to allow.
    case notNeeded
}

/// The permissions RememBear needs, as the setup window shows them.
public struct SetupState: Equatable, Sendable {
    /// Screen Recording: reading the window in front.
    public var screenRecording: PermissionState
    /// Accessibility: the global key monitor for Return and shortcuts.
    public var accessibility: PermissionState
    /// Automation of Chrome: asking whether a window is incognito.
    public var chrome: PermissionState

    public init(screenRecording: PermissionState, accessibility: PermissionState, chrome: PermissionState) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.chrome = chrome
    }

    /// Everything that's needed is on. Chrome counts once it's granted, or
    /// when it isn't installed at all.
    public var isComplete: Bool {
        screenRecording == .granted && accessibility == .granted && (chrome == .granted || chrome == .notNeeded)
    }

    /// How many of the needed ones are still to do, for the menu.
    public var remaining: Int {
        [screenRecording, accessibility, chrome].filter { $0 != .granted && $0 != .notNeeded }.count
    }
}
