import Foundation

/// Something wrong enough to tell Mike about through Sentry. Each is a fixed
/// message: nothing from his screen, titles, apps or summaries ever goes.
public enum Problem: String, CaseIterable, Sendable {
    case readStuck = "read-stuck"
    case relaunched = "relaunched"
    case relaunchFailed = "relaunch-failed"
    case notRecording = "not-recording"
    case summaryFailing = "summary-failing"

    public var message: String {
        switch self {
        case .readStuck: "A window read is stuck; recording windows without their text"
        case .relaunched: "A window read stayed stuck, so RememBear relaunched itself"
        case .relaunchFailed: "RememBear tried to relaunch and couldn't"
        case .notRecording: "No window recorded or skipped in 15 minutes of switching windows"
        case .summaryFailing: "A summary has failed three times"
        }
    }
}

/// Notices recording going quiet for any reason, not just the ones already
/// known. From 3 Nov 2026 RememBear recorded no window for two days with
/// nothing in the log, as one Vision read never came back.
///
/// While Mike is active, every new front window should end up recorded or
/// deliberately skipped (an excluded app, a private window, a key on
/// screen) within moments. If the front window changes `minChanges` times
/// over `quietFor` and none of them settle either way, recording is broken.
public struct RecordingHealth: Sendable {
    public let quietFor: TimeInterval
    public let minChanges: Int
    private var lastSettled: TimeInterval?
    private var lastFront: String?
    private var changes = 0
    private var reported = false

    public init(quietFor: TimeInterval = 15 * 60, minChanges: Int = 3) {
        self.quietFor = quietFor
        self.minChanges = minChanges
    }

    /// The front window while recording is on (not paused, idle or locked).
    /// Times are system uptime, which stands still while the Mac sleeps.
    public mutating func noteFront(_ key: String, uptime: TimeInterval) {
        if lastSettled == nil { lastSettled = uptime }
        if key != lastFront {
            lastFront = key
            changes += 1
        }
    }

    /// A window was recorded or deliberately left out.
    public mutating func settled(uptime: TimeInterval) {
        lastSettled = uptime
        changes = 0
        reported = false
    }

    /// `.notRecording` once per quiet stretch, else nil.
    public mutating func check(uptime: TimeInterval) -> Problem? {
        guard !reported, let lastSettled, changes >= minChanges, uptime - lastSettled >= quietFor else { return nil }
        reported = true
        return .notRecording
    }
}

/// A Sentry event as an envelope for its HTTP ingest endpoint, so RememBear
/// can report without an SDK (no third-party dependencies, AGENTS.md).
public struct SentryReport: Sendable {
    public let url: URL
    public let auth: String
    public let body: Data

    /// Nil if the DSN isn't one.
    public init?(dsn: String, problem: Problem, release: String, os: String, at: Date, eventID: UUID = UUID(),
                 environment: String = "production") {
        guard let c = URLComponents(string: dsn), let key = c.user, let host = c.host, let scheme = c.scheme,
              let project = c.path.split(separator: "/").last, !project.isEmpty else { return nil }
        var ingest = URLComponents()
        ingest.scheme = scheme
        ingest.host = host
        ingest.port = c.port
        ingest.path = "/api/\(project)/envelope/"
        guard let url = ingest.url else { return nil }
        let id = eventID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let event: [String: Any] = [
            "event_id": id,
            "timestamp": at.timeIntervalSince1970,
            "platform": "native",
            "level": "error",
            "logger": "remembear",
            "environment": environment,
            "release": release,
            "message": ["formatted": problem.message],
            // One issue per kind of problem, however often it happens.
            "fingerprint": [problem.rawValue],
            "tags": ["component": "mac", "problem": problem.rawValue],
            "contexts": ["os": ["name": "macOS", "version": os]],
        ]
        guard let header = try? JSONSerialization.data(withJSONObject: ["event_id": id, "dsn": dsn]),
              let payload = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return nil }
        var body = header
        body.append(Data("\n{\"type\":\"event\",\"length\":\(payload.count)}\n".utf8))
        body.append(payload)
        body.append(Data("\n".utf8))
        self.url = url
        auth = "Sentry sentry_version=7, sentry_key=\(key), sentry_client=remembear/1.0"
        self.body = body
    }
}
