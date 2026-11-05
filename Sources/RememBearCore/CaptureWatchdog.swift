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
    private var startedAt: Date?

    public init(slow: TimeInterval = 30, relaunchAfter: TimeInterval = 600, relaunchAtMostEvery: TimeInterval = 3600) {
        self.slow = slow
        self.relaunchAfter = relaunchAfter
        self.relaunchAtMostEvery = relaunchAtMostEvery
    }

    /// Call when a read starts; pass the token back to `finish`.
    public mutating func begin(at now: Date) -> Int {
        token += 1
        startedAt = now
        return token
    }

    /// Call when a read returns. False means it came back overdue (or isn't
    /// the current read), so what it read must be thrown away.
    public mutating func finish(_ t: Int, at now: Date) -> Bool {
        guard t == token, let startedAt else { return false }
        self.startedAt = nil
        return now.timeIntervalSince(startedAt) <= slow
    }

    public func check(at now: Date, lastRelaunch: Date?) -> State {
        guard let startedAt else { return .idle }
        let running = now.timeIntervalSince(startedAt)
        if running <= slow { return .reading }
        if running > relaunchAfter, lastRelaunch.map({ now.timeIntervalSince($0) >= relaunchAtMostEvery }) ?? true {
            return .relaunch
        }
        return .stuck
    }
}
