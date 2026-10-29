import Foundation

/// One thing that happened on the Mac, as written to the local event log.
/// Only events that passed the privacy rules are ever built, so nothing here
/// comes from an excluded app, an excluded site or a private browser window.
public struct RecordedEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The focused window changed (app switch, new tab, new page). Carries
        /// a text snapshot of the window.
        case windowChanged = "window.changed"
        /// Same window, but its text changed while Mike was using it. Carries
        /// only the lines that weren't in the previous snapshot.
        case snapshot = "window.snapshot"
        case click = "mouse.click"
        /// Return in a text field: a sent message, a search, a submitted form.
        case submit = "keyboard.submit"
        case shortcut = "keyboard.shortcut"
    }

    public var kind: Kind
    public var at: Date
    public var app: String
    public var bundleID: String
    public var windowTitle: String?
    public var url: String?
    public var target: Target?
    /// For shortcuts, e.g. "cmd+shift+t".
    public var keys: String?
    /// Window text from the accessibility tree.
    public var text: String?

    public init(kind: Kind, at: Date, app: String, bundleID: String, windowTitle: String? = nil, url: String? = nil, target: Target? = nil, keys: String? = nil, text: String? = nil) {
        self.kind = kind
        self.at = at
        self.app = app
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.url = url
        self.target = target
        self.keys = keys
        self.text = text
    }
}

/// The control a click, shortcut or submit landed on.
public struct Target: Codable, Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var description: String?
    public var placeholder: String?
    /// A text field's contents. Never set for secure fields or fields whose
    /// labels look like they hold secrets (see `Privacy.safeValue`).
    public var value: String?

    public init(role: String? = nil, subrole: String? = nil, title: String? = nil, description: String? = nil, placeholder: String? = nil, value: String? = nil) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.placeholder = placeholder
        self.value = value
    }

    /// The most human name for the control, for the digest.
    public var label: String? {
        [title, description, placeholder].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

public enum EventCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// One JSON object per line. A torn last line (the app was killed
    /// mid-write) is skipped rather than failing the whole segment.
    public static func decodeLines(_ data: Data) -> [RecordedEvent] {
        let decoder = decoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(RecordedEvent.self, from: Data($0)) }
    }
}
