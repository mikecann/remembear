import Foundation

/// Keeps one slow or stuck window read from stopping all recording.
///
/// The recorder runs one read at a time. On 3 Nov 2026 a Vision text read
/// blocked forever inside Apple's TextRecognition, and no window was recorded
/// for two days while keypresses carried on. A fresh copy of the app can also
/// wait minutes on its first read while the Neural Engine compiles Vision's
/// model (5 Nov 2026), and quitting then throws that compile away.
///
/// So a read that runs past `slow` is left to finish while windows are
/// recorded without their text, and what it returns is dropped as stale. Only
/// one stuck for `relaunchAfter` is worth a fresh copy of the app, and not
/// more than once in `relaunchAtMostEvery`, so a wedged system service can't
/// turn into a relaunch loop.
public struct CaptureWatchdog: Sendable {
    public enum State: Equatable, Sendable {
        /// No read running: start one.
        case idle
        /// A read is running and still has time: wait for it.
        case reading
        /// The read is overdue: record windows without text meanwhile.
        case stuck
        /// The read has been stuck long enough to relaunch the app.
        case relaunch
    }

    public let slow: TimeInterval
    public let relaunchAfter: TimeInterval
    public let relaunchAtMostEvery: TimeInterval
    private var token = 0
    /// System uptime when the read began: it stands still while the Mac
    /// sleeps, so a read across a sleep doesn't look stuck, and it can't be
    /// set back like the wall clock.
    private var startedAt: TimeInterval?
    /// Once a read has been treated as stuck, its result stays stale.
    private var overdue = false

    public init(slow: TimeInterval = 30, relaunchAfter: TimeInterval = 600, relaunchAtMostEvery: TimeInterval = 3600) {
        self.slow = slow
        self.relaunchAfter = relaunchAfter
        self.relaunchAtMostEvery = relaunchAtMostEvery
    }

    /// Call when a read starts; pass the token back to `finish`.
    public mutating func begin(uptime: TimeInterval) -> Int {
        token += 1
        startedAt = uptime
        overdue = false
        return token
    }

    /// Call when a read returns. False means it came back overdue (or isn't
    /// the current read), so what it read must be thrown away.
    public mutating func finish(_ t: Int, uptime: TimeInterval) -> Bool {
        guard t == token, let startedAt else { return false }
        self.startedAt = nil
        return !overdue && uptime - startedAt <= slow
    }

    /// `now` is the wall clock, only for spacing relaunches across launches.
    public mutating func check(uptime: TimeInterval, now: Date, lastRelaunch: Date?) -> State {
        guard let startedAt else { return .idle }
        let running = uptime - startedAt
        if running <= slow, !overdue { return .reading }
        overdue = true
        if running > relaunchAfter, lastRelaunch.map({ now.timeIntervalSince($0) >= relaunchAtMostEvery }) ?? true {
            return .relaunch
        }
        return .stuck
    }
}
