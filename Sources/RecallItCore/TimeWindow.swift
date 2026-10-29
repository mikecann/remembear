import Foundation

public enum Resolution: String, Codable, Sendable, CaseIterable {
    case tenMinutes = "10min"
    case sixHours = "6h"

    public var duration: TimeInterval {
        switch self {
        case .tenMinutes: 10 * 60
        case .sixHours: 6 * 60 * 60
        }
    }
}

/// A summary window, aligned to UTC like Codex's: 10-minute windows start on
/// :00, :10 … and 6-hour windows at 00:00, 06:00, 12:00 and 18:00 UTC.
public struct TimeWindow: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let resolution: Resolution
    public let start: Date

    public init(resolution: Resolution, start: Date) {
        self.resolution = resolution
        self.start = start
    }

    public static func containing(_ date: Date, _ resolution: Resolution) -> TimeWindow {
        let seconds = floor(date.timeIntervalSince1970 / resolution.duration) * resolution.duration
        return TimeWindow(resolution: resolution, start: Date(timeIntervalSince1970: seconds))
    }

    public var end: Date { start.addingTimeInterval(resolution.duration) }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    public var next: TimeWindow { TimeWindow(resolution: resolution, start: end) }

    /// The 10-minute windows inside a 6-hour one.
    public var tenMinuteWindows: [TimeWindow] {
        stride(from: start.timeIntervalSince1970, to: end.timeIntervalSince1970, by: Resolution.tenMinutes.duration)
            .map { TimeWindow(resolution: .tenMinutes, start: Date(timeIntervalSince1970: $0)) }
    }

    /// "2026-10-29T06-20-00", the start time in UTC as used in file names.
    public var stamp: String { Self.stampFormatter.string(from: start) }

    /// "2026-10-29T06-20-00Z", the event segment's folder-safe id.
    public var segmentID: String { stamp + "Z" }

    public static func parseSegmentID(_ id: String) -> TimeWindow? {
        guard id.hasSuffix("Z"), let date = stampFormatter.date(from: String(id.dropLast())) else { return nil }
        let window = containing(date, .tenMinutes)
        return window.start == date ? window : nil
    }

    public static func < (a: TimeWindow, b: TimeWindow) -> Bool {
        a.start == b.start ? a.resolution.duration < b.resolution.duration : a.start < b.start
    }

    public var description: String { "\(resolution.rawValue) \(stamp)" }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f
    }()
}

/// Summary file names, in Codex's format so Agent Archive (and anything else
/// that read Codex's summaries) picks them up unchanged:
/// `YYYY-MM-DDTHH-MM-SS-xxxx-10min-memory-summary.md`, time in UTC.
public enum SummaryFileName {
    public static func make(_ window: TimeWindow, tag: String = randomTag()) -> String {
        "\(window.stamp)-\(tag)-\(window.resolution.rawValue)-memory-summary.md"
    }

    public static func randomTag() -> String {
        String((0..<4).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()! })
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})-[A-Za-z]{4}-(10min|6h)-[A-Za-z0-9_-]{1,120}\.md$"#)

    public static func parse(_ name: String) -> TimeWindow? {
        let ns = name as NSString
        guard let m = pattern.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
              let resolution = Resolution(rawValue: ns.substring(with: m.range(at: 2))),
              let segment = TimeWindow.parseSegmentID(ns.substring(with: m.range(at: 1)) + "Z") else { return nil }
        let window = TimeWindow.containing(segment.start, resolution)
        return window.start == segment.start ? window : nil
    }
}
