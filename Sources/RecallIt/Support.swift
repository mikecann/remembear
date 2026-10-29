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

// Private, but stable since 10.6 and used by every window manager. It's the
// only way from an AX window to its CGWindowID, which tells two windows with
// the same title apart.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func attr(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success ? v : nil
    }

    func string(_ name: String) -> String? { attr(name) as? String }

    func element(_ name: String) -> AXUIElement? {
        guard let v = attr(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    // One round trip for many attributes. Each AX call is an IPC to the app,
    // so on a big Chrome page this is the difference between a second and ten.
    func values(_ names: [String]) -> [String: AnyObject] {
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(self, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
              let list = out as? [AnyObject] else { return [:] }
        var d: [String: AnyObject] = [:]
        for (i, v) in list.enumerated() where i < names.count {
            // Missing attributes come back as an AXValue holding an error.
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { continue }
            d[names[i]] = v
        }
        return d
    }

    @discardableResult func set(_ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(self, &p)
        return p
    }

    var windowID: CGWindowID {
        var id: CGWindowID = 0
        _ = _AXUIElementGetWindow(self, &id)
        return id
    }
}
