import AppKit
import ApplicationServices

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
/// (`CaptureWatchdog`). False, and nothing quits, if the helper that opens
/// the new copy can't start.
enum Relaunch {
    @discardableResult
    static func now() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // If `open` fails the old copy is gone, so the failure is logged
        // where Mike would look.
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\" || echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) relaunch: open failed\" >> \"$1\"",
                       Bundle.main.bundlePath, Paths.log.path]
        do { try p.run() } catch {
            Log.info("couldn't start the relaunch helper: \(error.localizedDescription)")
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}
