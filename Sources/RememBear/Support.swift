import AppKit
import ApplicationServices
import RememBearCore

enum Paths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RememBear", isDirectory: true)
    /// Raw events, one JSONL file per 10-minute window, deleted after 48 hours.
    static let events = support.appendingPathComponent("events", isDirectory: true)
    /// The summaries. Agent Archive reads this folder.
    static let summaries = support.appendingPathComponent("summaries", isDirectory: true)
    /// An empty working folder for `claude`, so it never picks up a project's
    /// CLAUDE.md or settings.
    static let claudeCwd = support.appendingPathComponent("claude-cwd", isDirectory: true)
    static let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/remembear.log")

    /// Owner-only folders: this is a record of everything Mike does.
    static func ensure() {
        // RememBear was Recall It until 30 Oct 2026: its events and summaries
        // move across once, file names and all, so Agent Archive (which
        // keys summaries by file name) doesn't read them twice.
        let old = support.deletingLastPathComponent().appendingPathComponent("Recall It", isDirectory: true)
        if !FileManager.default.fileExists(atPath: support.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: support)
        }
        for dir in [support, events, summaries, claudeCwd] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "remembear.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let url = Paths.log
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// Quits and opens a new copy once this one has gone: for a Screen
/// Recording grant to take, or when a window read is stuck
/// (`CaptureWatchdog`). False, and nothing quits, if the app can't be
/// opened again or the helper that opens it can't start.
enum Relaunch {
    @discardableResult
    static func now() -> Bool {
        let path = Bundle.main.bundlePath
        // Once this copy quits nothing records, so make sure there's an app
        // to open first (it may have been moved or deleted since launch).
        guard let exe = Bundle.main.executablePath, FileManager.default.isExecutableFile(atPath: exe) else {
            Log.info("can't relaunch: the app isn't at \(path) any more")
            Reporter.report(.relaunchFailed)
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `open` gets three goes. If all fail, nothing of RememBear is left
        // running, so the helper itself logs it and tells Sentry with curl.
        let report = Reporter.enabled ? Reporter.envelope(.relaunchFailed) : nil
        p.arguments = ["-c", """
            for i in 1 2 3; do sleep 1; /usr/bin/open "$0" && exit 0; sleep 4; done
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) relaunch: open failed three times" >> "$1"
            [ -n "$2" ] && printf %s "$4" | /usr/bin/curl -s --max-time 15 -o /dev/null -H "Content-Type: application/x-sentry-envelope" -H "X-Sentry-Auth: $3" --data-binary @- "$2"
            exit 1
            """, path, Paths.log.path, report?.url.absoluteString ?? "", report?.auth ?? "",
                       report.map { String(decoding: $0.body, as: UTF8.self) } ?? ""]
        do { try p.run() } catch {
            Log.info("couldn't start the relaunch helper: \(error.localizedDescription)")
            Reporter.report(.relaunchFailed)
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}

/// Tells Mike's Sentry (org mikec, project remembear) when recording breaks,
/// with fixed messages only (`Problem`): nothing from his screen, titles,
/// apps or summaries. sentry-watch then opens a triage thread for it.
///
/// Only the real install reports: a Release build at ~/Applications. Debug
/// builds, `swift test` and isolated test installs (REMEMBEAR_APP_PATH)
/// never do, so agents trying things don't page Mike.
enum Reporter {
    /// A public client key; it ships in the app anyway.
    static let dsn = "https://a5539c96b7e3f15b794f8af1d2081fab@o4508736647266304.ingest.us.sentry.io/4512376856903680"

    static var enabled: Bool {
        #if DEBUG
        return false
        #else
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/RememBear.app")
        return URL(fileURLWithPath: Bundle.main.bundlePath).standardizedFileURL.path == installed.standardizedFileURL.path
        #endif
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastSent: [Problem: Date] = [:]

    /// At most once an hour per kind of problem.
    static func report(_ problem: Problem) {
        Log.info("problem: \(problem.message)\(enabled ? "; reported to Sentry" : "")")
        guard enabled, let report = envelope(problem) else { return }
        let due = lock.withLock { () -> Bool in
            if let last = lastSent[problem], Date().timeIntervalSince(last) < 3600 { return false }
            lastSent[problem] = Date()
            return true
        }
        guard due else { return }
        var request = URLRequest(url: report.url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        request.setValue(report.auth, forHTTPHeaderField: "X-Sentry-Auth")
        request.httpBody = report.body
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error != nil || status >= 300 { Log.info("couldn't report \(problem.rawValue) to Sentry (\(status))") }
        }.resume()
    }

    static func envelope(_ problem: Problem) -> SentryReport? {
        let info = Bundle.main.infoDictionary
        let release = "remembear@\(info?["CFBundleShortVersionString"] as? String ?? "?")+\(info?["CFBundleVersion"] as? String ?? "?")"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return SentryReport(dsn: dsn, problem: problem, release: release, os: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", at: Date())
    }
}
