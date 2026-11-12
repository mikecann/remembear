import Foundation

/// Which summaries are due. Pure functions over what's on disk, so a restart,
/// a sleep or a failed call just means the next pass picks the work up.
public enum Schedule {
    /// Wait a little after a window ends, so late events are in.
    public static let tenMinuteGrace: TimeInterval = 90
    /// The 6-hour rollup waits for the last 10-minute summaries inside it.
    public static let sixHourGrace: TimeInterval = 10 * 60
    /// Raw events are deleted after this, like Codex's. Summaries are kept.
    public static let rawRetention: TimeInterval = 48 * 60 * 60
    /// A window that never got its summary keeps its events longer, so a
    /// Claude login out of its weekly limit (12 Nov 2026: four days of
    /// failures) delays summaries rather than losing them. A week covers any
    /// weekly reset.
    public static let unsummarizedRetention: TimeInterval = 7 * 24 * 60 * 60
    /// How far back to look for missing 6-hour rollups: past the longest a
    /// 10-minute summary can still turn up, so a late backlog still rolls up.
    public static let sixHourLookback: TimeInterval = 8 * 24 * 60 * 60

    /// 10-minute windows with recorded events, closed for a moment, with no
    /// summary yet and not waiting out a retry, oldest first.
    public static func dueTenMinute(segments: Set<TimeWindow>, summarized: Set<TimeWindow>, retryAfter: [TimeWindow: Date], now: Date) -> [TimeWindow] {
        segments
            .filter { $0.end.addingTimeInterval(tenMinuteGrace) <= now && !summarized.contains($0) }
            .filter { retryAfter[$0].map { $0 <= now } ?? true }
            .sorted()
    }

    /// 6-hour windows that have ended, have at least one 10-minute summary,
    /// no rollup yet, and nothing inside still waiting to be summarised.
    public static func dueSixHour(tenMinuteSummaries: Set<TimeWindow>, sixHourSummaries: Set<TimeWindow>, pendingTenMinute: Set<TimeWindow>, now: Date) -> [TimeWindow] {
        let candidates = Set(tenMinuteSummaries.map { TimeWindow.containing($0.start, .sixHours) })
        return candidates
            .filter { $0.end.addingTimeInterval(sixHourGrace) <= now && $0.end > now.addingTimeInterval(-sixHourLookback) }
            .filter { !sixHourSummaries.contains($0) }
            .filter { six in !pendingTenMinute.contains { six.contains($0.start) } }
            .sorted()
    }

    /// Event segments old enough to delete: 48 hours once summarised, a week
    /// if not.
    public static func expired(_ segments: Set<TimeWindow>, summarized: Set<TimeWindow>, now: Date) -> [TimeWindow] {
        segments.filter { $0.end.addingTimeInterval(summarized.contains($0) ? rawRetention : unsummarizedRetention) < now }.sorted()
    }

    /// 2, 10 and 30 minutes, then hourly. Claude being down or rate limited
    /// for a while shouldn't lose a window; its events wait a week for it.
    public static func retryDelay(attempt: Int) -> TimeInterval {
        let minutes: [Double] = [2, 10, 30]
        return attempt < minutes.count ? minutes[max(0, attempt)] * 60 : 60 * 60
    }
}
