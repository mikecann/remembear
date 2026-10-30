import AppKit
import ApplicationServices

enum Paths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Recall It", isDirectory: true)
    /// Raw events, one JSONL file per 10-minute window, deleted after 48 hours.
    static let events = support.appendingPathComponent("events", isDirectory: true)
    /// The summaries. Agent Archive reads this folder.
    static let summaries = support.appendingPathComponent("summaries", isDirectory: true)
    /// An empty working folder for `claude`, so it never picks up a project's
    /// CLAUDE.md or settings.
    static let claudeCwd = support.appendingPathComponent("claude-cwd", isDirectory: true)
    static let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/recall-it.log")

    /// Owner-only folders: this is a record of everything Mike does.
    static func ensure() {
        for dir in [support, events, summaries, claudeCwd] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "recall-it.log")
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
