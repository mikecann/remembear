import Foundation
import RememBearCore

/// Writes the 10-minute and 6-hour summaries with `claude -p` on Mike's own
/// subscription, and deletes raw events after 48 hours. Each pass works out
/// what's due from the files on disk, so a restart or a failed call is
/// picked up on the next pass.
final class Summarizer {
    private let settings: Settings
    private let store: EventStore
    private let work = DispatchQueue(label: "remembear.summarize")
    private var timer: Timer?
    private var running = false
    private var attempts: [TimeWindow: Int] = [:]
    private var retryAfter: [TimeWindow: Date] = [:]

    /// For the menu: the newest summary's title and file, and the last error.
    private(set) var latest: (title: String, url: URL)?
    private(set) var lastError: String?

    init(settings: Settings, store: EventStore) {
        self.settings = settings
        self.store = store
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.kick() }
        timer?.tolerance = 10
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.kick() }
        work.async { [self] in latest = newestSummary() }
    }

    func kick() {
        work.async { [self] in
            guard !running else { return }
            running = true
            defer { running = false }
            pass()
        }
    }

    // MARK: The pass

    private func pass() {
        let now = Date()
        var segments = store.segments()
        for old in Schedule.expired(segments, now: now) {
            store.delete(old)
            segments.remove(old)
            Log.info("deleted raw events for \(old)")
        }

        var summaries = summaryFiles()
        let due = Schedule.dueTenMinute(segments: segments, summarized: Set(summaries.keys), retryAfter: retryAfter, now: now)
        // A cap per pass keeps a long backlog from hogging the subscription
        // in one go; the next pass carries on.
        for window in due.prefix(12) {
            if let url = summarizeTenMinutes(window, summaries: summaries) { summaries[window] = url }
        }

        let tenMinute = Set(summaries.keys.filter { $0.resolution == .tenMinutes })
        let sixHour = Set(summaries.keys.filter { $0.resolution == .sixHours })
        let pending = segments.subtracting(tenMinute).filter { $0.end <= now }
        for window in Schedule.dueSixHour(tenMinuteSummaries: tenMinute, sixHourSummaries: sixHour, pendingTenMinute: pending, now: now)
            where retryAfter[window].map({ $0 <= now }) ?? true {
            summarizeSixHours(window, summaries: summaries)
        }
    }

    private func summarizeTenMinutes(_ window: TimeWindow, summaries: [TimeWindow: URL]) -> URL? {
        let events = store.read(window)
        guard !events.isEmpty else { store.delete(window); return nil }
        let digest = Digest.render(events)
        // The summary just before, if it's recent, for continuity.
        let previous = summaries.filter { $0.key.resolution == .tenMinutes && $0.key.start < window.start && $0.key.start > window.start.addingTimeInterval(-3600) }
            .max { $0.key < $1.key }
        let previousBody = previous.flatMap { try? String(contentsOf: $0.value, encoding: .utf8) }.map(SummaryFile.body(of:))
        let prompt = Prompts.tenMinute(window: window, digest: digest, previousSummary: previousBody)
        var citations = [EventStore.url(window).path]
        if let previous { citations.append(previous.value.path) }
        return write(window, model: settings.tenMinuteModel, system: Prompts.tenMinuteSystem, prompt: prompt,
                     applications: Digest.applications(events), citations: citations, detail: "\(events.count) events, \(digest.count) chars")
    }

    private func summarizeSixHours(_ window: TimeWindow, summaries: [TimeWindow: URL]) {
        let children = summaries.filter { $0.key.resolution == .tenMinutes && window.contains($0.key.start) }.sorted { $0.key < $1.key }
        let texts = children.compactMap { c in (try? String(contentsOf: c.value, encoding: .utf8)).map { (c.key, $0) } }
        guard !texts.isEmpty else { return }
        let previous = summaries[TimeWindow(resolution: .sixHours, start: window.start.addingTimeInterval(-Resolution.sixHours.duration))]
        let previousBody = previous.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(SummaryFile.body(of:))
        let prompt = Prompts.sixHour(window: window, children: texts.map { ($0.0, SummaryFile.body(of: $0.1)) }, previousRollup: previousBody)
        var apps: [String] = []
        for (_, text) in texts { for a in Self.applications(in: text) where !apps.contains(a) { apps.append(a) } }
        _ = write(window, model: settings.sixHourModel, system: Prompts.sixHourSystem, prompt: prompt,
                  applications: apps, citations: children.map(\.value.path), detail: "\(texts.count) summaries")
    }

    private func write(_ window: TimeWindow, model: String, system: String, prompt: String, applications: [String], citations: [String], detail: String) -> URL? {
        let started = Date()
        do {
            let reply = try Claude.run(settings: settings, model: model, system: system, prompt: prompt)
            let draft = try SummaryFile.parseReply(reply)
            let file = SummaryFile.render(draft, applications: applications, citations: citations)
            let url = Paths.summaries.appendingPathComponent(SummaryFileName.make(window))
            // Written under a name Agent Archive ignores, then renamed, so a
            // half-written file is never picked up.
            let temp = Paths.summaries.appendingPathComponent(".writing-\(UUID().uuidString)")
            try Data(file.utf8).write(to: temp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            try FileManager.default.moveItem(at: temp, to: url)
            attempts[window] = nil
            retryAfter[window] = nil
            lastError = nil
            latest = (draft.title, url)
            Log.info("wrote \(window) with \(model) in \(Int(Date().timeIntervalSince(started)))s (\(detail)): \(draft.title)")
            return url
        } catch {
            let n = attempts[window, default: 0]
            attempts[window] = n + 1
            retryAfter[window] = Date().addingTimeInterval(Schedule.retryDelay(attempt: n))
            lastError = "\(error)"
            Log.info("failed \(window) (attempt \(n + 1), \(detail)): \(error)")
            return nil
        }
    }

    // MARK: Files

    /// Every summary on disk, by window. If a window somehow has two, the
    /// newest wins.
    func summaryFiles() -> [TimeWindow: URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.summaries.path)) ?? []
        var out: [TimeWindow: URL] = [:]
        for name in names.sorted() {
            if let w = SummaryFileName.parse(name) { out[w] = Paths.summaries.appendingPathComponent(name) }
        }
        return out
    }

    private func newestSummary() -> (String, URL)? {
        guard let newest = summaryFiles().filter({ $0.key.resolution == .tenMinutes }).max(by: { $0.key < $1.key }),
              let text = try? String(contentsOf: newest.value, encoding: .utf8) else { return nil }
        return (SummaryFile.title(of: text) ?? newest.value.lastPathComponent, newest.value)
    }

    /// Deletes summaries and raw events whose window overlaps the last
    /// `interval`. Agent Archive mirrors recent deletions, so its copies go too.
    func forget(last interval: TimeInterval) {
        work.async { [self] in
            let since = Date().addingTimeInterval(-interval)
            store.deleteAll(since: since)
            for (w, url) in summaryFiles() where w.end > since {
                try? FileManager.default.removeItem(at: url)
            }
            latest = newestSummary()
            Log.info("forgot everything since \(since)")
        }
    }

    static func applications(in file: String) -> [String] {
        guard let line = file.split(separator: "\n").prefix(20).first(where: { $0.hasPrefix("applications:") }),
              let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]") else { return [] }
        return line[line.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// `claude -p` with no tools, no MCP servers, no settings, hooks or
/// CLAUDE.md, and no saved session, so each summary is one plain model call
/// on Mike's subscription and doesn't turn up as a thread anywhere.
enum Claude {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(settings: Settings, model: String, system: String, prompt: String, timeout: TimeInterval = 300) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.claudePath)
        p.arguments = ["-p", "--model", model, "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                       "--setting-sources", "", "--system-prompt", system, "--output-format", "json"]
        p.currentDirectoryURL = Paths.claudeCwd
        let home = NSHomeDirectory()
        var env = ["HOME": home, "USER": NSUserName(), "LANG": "en_US.UTF-8",
                   "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        if let dir = settings.claudeConfigDir { env["CLAUDE_CONFIG_DIR"] = dir }
        p.environment = env
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors

        var out = Data(), err = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { out = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        do { try p.run() } catch { throw Failure(description: "couldn't start \(settings.claudePath): \(error.localizedDescription)") }
        DispatchQueue.global().async {
            input.fileHandleForWriting.write(Data(prompt.utf8))
            try? input.fileHandleForWriting.close()
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        group.wait()

        guard let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else {
            let tail = String(decoding: err.suffix(400), as: UTF8.self) + String(decoding: out.suffix(400), as: UTF8.self)
            throw Failure(description: "claude exited \(p.terminationStatus) without JSON: \(tail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if (json["is_error"] as? Bool) == true {
            throw Failure(description: "claude error: \((json["result"] as? String) ?? (json["subtype"] as? String) ?? "unknown")")
        }
        guard let result = json["result"] as? String, !result.isEmpty else {
            throw Failure(description: "claude returned no result")
        }
        return result
    }
}
