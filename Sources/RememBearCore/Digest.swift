import Foundation

/// Turns a 10-minute window's events into compact text for the summariser.
/// A raw window can be a megabyte of window text, mostly the same page read
/// again and again, so each line of window text is only shown the first time
/// it appears, and the whole digest has a character budget.
public enum Digest {
    public struct Options: Sendable {
        public var budget: Int
        public var perSnapshot: Int
        public var timeZone: TimeZone

        public init(budget: Int = 60_000, perSnapshot: Int = 3_000, timeZone: TimeZone = .current) {
            self.budget = budget
            self.perSnapshot = perSnapshot
            self.timeZone = timeZone
        }
    }

    public static func render(_ events: [RecordedEvent], options: Options = Options()) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = options.timeZone
        clock.dateFormat = "HH:mm:ss"

        var seen = Set<String>()
        var out: [String] = []
        var used = 0
        var textDropped = false
        var lastPlace: String?

        for e in events.sorted(by: { $0.at < $1.at }) {
            let time = clock.string(from: e.at)
            var lines: [String] = []
            // Name the app and window again only when it changes, which keeps
            // runs of clicks in one window short.
            let place = "\(e.app) | \(e.windowTitle ?? "untitled window")" + (e.url.map { " | \($0)" } ?? "")
            switch e.kind {
            case .windowChanged:
                lines.append("\(time) window: \(place)")
                lastPlace = place
            case .snapshot:
                if place != lastPlace {
                    lines.append("\(time) window: \(place)")
                    lastPlace = place
                }
            case .click, .submit, .shortcut:
                if place != lastPlace {
                    lines.append("\(time) in: \(place)")
                    lastPlace = place
                }
                lines.append("\(time) \(describe(e))")
            }

            if let text = e.text {
                var fresh: [String] = []
                var size = 0
                for raw in text.split(whereSeparator: \.isNewline) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    guard line.count > 1, !seen.contains(line), !fresh.contains(line) else { continue }
                    if size + line.count > options.perSnapshot { textDropped = true; break }
                    fresh.append(line)
                    size += line.count + 1
                }
                if !fresh.isEmpty {
                    if used + size > options.budget {
                        textDropped = true
                    } else {
                        // Only text that made it in counts as seen, so a line
                        // dropped here can still show up in a later snapshot.
                        seen.formUnion(fresh)
                        lines.append("  text:")
                        lines.append(contentsOf: fresh.map { "    " + $0 })
                    }
                }
            }

            let chunk = lines.joined(separator: "\n")
            // Event lines are kept even past the budget, up to twice it, so
            // the order of what happened survives a text-heavy window.
            if used + chunk.count > options.budget * 2 { textDropped = true; break }
            if !chunk.isEmpty {
                out.append(chunk)
                used += chunk.count + 1
            }
        }
        if textDropped { out.append("(Some repeated or very long window text was left out to keep this short.)") }
        return out.joined(separator: "\n")
    }

    static func describe(_ e: RecordedEvent) -> String {
        let t = e.target
        let control = [t?.role.map(friendlyRole), t?.label.map { "\"\(clip($0, 120))\"" }].compactMap { $0 }.joined(separator: " ")
        switch e.kind {
        case .click:
            return "click: " + (control.isEmpty ? "somewhere in the window" : control)
        case .submit:
            let value = t?.value.map { ": \"\(clip($0, 1_500))\"" } ?? ""
            return "pressed Return in " + (control.isEmpty ? "a text field" : control) + value
        case .shortcut:
            return "shortcut: \(e.keys ?? "?")" + (control.isEmpty ? "" : " (focus: \(control))")
        case .windowChanged, .snapshot:
            return ""
        }
    }

    static func friendlyRole(_ role: String) -> String {
        let trimmed = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        return trimmed.lowercased()
    }

    static func clip(_ s: String, _ max: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " / ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// Bundle ids in the order they first appear, for the summary frontmatter.
    public static func applications(_ events: [RecordedEvent]) -> [String] {
        var seen = Set<String>()
        return events.sorted { $0.at < $1.at }.map(\.bundleID)
            .filter { !$0.isEmpty && $0 != "?" && $0 != "unknown" && seen.insert($0).inserted }
    }
}
