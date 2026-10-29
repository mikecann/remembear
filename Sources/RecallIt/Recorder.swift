import AppKit
import ApplicationServices
import RecallItCore

/// Watches what Mike does through the Accessibility API: the focused window
/// and its text, clicks, Return in text fields, and keyboard shortcuts. No
/// screenshots, no audio, and no per-keystroke log: typed text is only read
/// from the field when Return sends it.
///
/// Every check against the privacy rules happens before an event is built,
/// so nothing from an excluded app, an excluded site or a private window is
/// ever written down.
final class Recorder {
    enum Status: Equatable {
        case recording, paused(until: Date), needsAccess, idle, locked
    }

    private let settings: Settings
    private let store: EventStore
    private let ax = DispatchQueue(label: "recall-it.ax")
    private var timer: Timer?
    private var monitors: [Any] = []
    private var trusted = false
    private var lastClick = Date.distantPast
    private var typingRead: DispatchWorkItem?

    // Only touched on the ax queue.
    private var lastKey: String?
    private var pendingKey: String?
    private var lastLines = Set<String>()
    private var lastSnapshot = Date.distantPast
    private var webTurnedOn = Set<pid_t>()
    private var typed: (element: AXUIElement, value: String, at: Date)?
    /// The last polled window's URL, so clicks in it can be checked against
    /// excluded sites without walking the page again.
    private var lastWindow: (pid: pid_t, windowID: CGWindowID, url: String?)?

    /// Read on the main thread for the menu.
    private(set) var frontURL: (bundleID: String, url: String)?
    private(set) var suppressed = 0

    private let snapshotEvery: TimeInterval = 60
    private let idleAfter: TimeInterval = 5 * 60
    private let maxText = 12_000

    init(settings: Settings, store: EventStore) {
        self.settings = settings
        self.store = store
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.5
        refreshTrust()
    }

    var status: Status {
        if !AXIsProcessTrusted() { return .needsAccess }
        if let until = settings.pausedUntil, until > Date() { return .paused(until: until) }
        if Self.screenLocked { return .locked }
        if Self.idleSeconds > idleAfter { return .idle }
        return .recording
    }

    // Key monitors only deliver once the app is trusted, so they're
    // (re)installed when trust is granted.
    private func refreshTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted || monitors.isEmpty else { return }
        trusted = now
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.clicked() }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in self?.keyDown(e) }) { monitors.append(m) }
        Log.info("accessibility \(now ? "granted" : "not granted"); monitors installed")
    }

    private func shouldRecord() -> Bool { status == .recording }

    // MARK: Window polling

    private func tick() {
        refreshTrust()
        guard shouldRecord(), let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let info = AppInfo(app)
        let rules = settings.rules
        if rules.isExcludedApp(info.bundleID) { skip(); return }
        ax.async { [self] in poll(info, rules) }
    }

    private func skip() {
        ax.async { [self] in
            suppressed += 1
            lastKey = nil
            pendingKey = nil
        }
        frontURL = nil
    }

    private func poll(_ app: AppInfo, _ rules: PrivacyRules) {
        let appEl = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        ensureWeb(app, appEl)
        guard let win = appEl.element(kAXFocusedWindowAttribute) else { return }
        let title = win.string(kAXTitleAttribute)
        // Private windows are ruled out on the title, before any text is read.
        guard rules.allows(bundleID: app.bundleID, windowTitle: title, url: nil) else {
            suppressed += 1
            lastKey = nil
            DispatchQueue.main.async { self.frontURL = nil }
            return
        }
        // Keep the focused field's contents fresh for when Return sends it.
        // Typing triggers a read too, but dictated or pasted text (Voice
        // Type) arrives without keystrokes.
        readTyped()
        let key = "\(app.bundleID)|\(win.windowID)|\(title ?? "")"
        let now = Date()
        let changed = key != lastKey
        if changed {
            // Wait for the same window on two ticks in a row, so loading
            // titles and windows flicked past don't count.
            guard key == pendingKey else { pendingKey = key; return }
        } else if now.timeIntervalSince(lastSnapshot) < snapshotEvery || Self.idleSeconds > snapshotEvery {
            return
        }

        let (text, url) = readWindow(win, isBrowser: Privacy.isBrowser(app.bundleID))
        lastWindow = (app.pid, win.windowID, url)
        guard rules.allows(bundleID: app.bundleID, windowTitle: title, url: url) else {
            suppressed += 1
            lastKey = key
            lastLines = []
            DispatchQueue.main.async { self.frontURL = nil }
            return
        }
        DispatchQueue.main.async { self.frontURL = url.map { (app.bundleID, $0) } }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        lastSnapshot = now
        if changed {
            lastKey = key
            lastLines = Set(lines)
            store.append(RecordedEvent(kind: .windowChanged, at: now, app: app.name, bundleID: app.bundleID, windowTitle: title, url: url, text: text.isEmpty ? nil : text))
        } else {
            let fresh = lines.filter { !lastLines.contains($0) }
            lastLines = Set(lines)
            guard !fresh.isEmpty else { return }
            store.append(RecordedEvent(kind: .snapshot, at: now, app: app.name, bundleID: app.bundleID, windowTitle: title, url: url, text: fresh.joined(separator: "\n")))
        }
    }

    // Chromium and Electron only build their accessibility tree for web
    // content when they think assistive tech is listening. AXManualAccessibility
    // asks for it without AXEnhancedUserInterface's window-animation side
    // effects; Chrome itself needs the latter.
    private func ensureWeb(_ app: AppInfo, _ appEl: AXUIElement) {
        guard !webTurnedOn.contains(app.pid) else { return }
        webTurnedOn.insert(app.pid)
        let manual = appEl.set("AXManualAccessibility", kCFBooleanTrue)
        if manual != .success, Privacy.isBrowser(app.bundleID) {
            appEl.set("AXEnhancedUserInterface", kCFBooleanTrue)
        }
    }

    /// The window's visible words, as Mitts reads them, and the page URL for
    /// browsers. Secure fields are skipped and secrets masked.
    private func readWindow(_ win: AXUIElement, isBrowser: Bool) -> (String, String?) {
        var out: [String] = []
        var size = 0
        var visited = 0
        var url: String?
        let started = Date()
        func walk(_ el: AXUIElement, _ depth: Int) {
            visited += 1
            guard visited < 6_000, depth < 100, size < maxText, Date().timeIntervalSince(started) < 0.8 else { return }
            let v = el.values([kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
            let role = v[kAXRoleAttribute] as? String ?? ""
            var text: String?
            switch role {
            case "AXWebArea":
                if url == nil, let u = el.attr("AXURL") { url = (u as? URL)?.absoluteString ?? (u as? String) }
            case "AXStaticText":
                text = v[kAXValueAttribute] as? String
            case "AXHeading":
                if let t = (v[kAXTitleAttribute] as? String) ?? (v[kAXDescriptionAttribute] as? String), !t.isEmpty {
                    text = "## " + t
                }
            case "AXTextField", "AXTextArea", "AXComboBox":
                text = Privacy.safeValue(v[kAXValueAttribute] as? String, role: role, subrole: v[kAXSubroleAttribute] as? String,
                                         labels: [v[kAXTitleAttribute] as? String, v[kAXDescriptionAttribute] as? String, el.string(kAXPlaceholderValueAttribute)])
            case "AXSecureTextField", "AXScrollBar", "AXMenuBar", "AXMenu":
                return
            default: break
            }
            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, out.last != t {
                out.append(t)
                size += t.count + 1
            }
            for k in v[kAXChildrenAttribute] as? [AXUIElement] ?? [] { walk(k, depth + 1) }
        }
        walk(win, 0)
        if isBrowser, url == nil { url = findURL(win) }
        let text = Privacy.redactSecrets(out.joined(separator: "\n"))
        return (text.count > maxText ? String(text.prefix(maxText)) : text, url)
    }

    // When the text walk ran out of budget before the page.
    private func findURL(_ win: AXUIElement) -> String? {
        var queue = [win]
        var seen = 0
        while !queue.isEmpty, seen < 400 {
            let el = queue.removeFirst()
            seen += 1
            let v = el.values([kAXRoleAttribute, kAXChildrenAttribute])
            if v[kAXRoleAttribute] as? String == "AXWebArea", let u = el.attr("AXURL") {
                return (u as? URL)?.absoluteString ?? (u as? String)
            }
            queue.append(contentsOf: v[kAXChildrenAttribute] as? [AXUIElement] ?? [])
        }
        return nil
    }

    // MARK: Clicks

    private func clicked() {
        guard shouldRecord(), Date().timeIntervalSince(lastClick) > 0.25 else { return }
        lastClick = Date()
        let loc = NSEvent.mouseLocation
        // AX uses top-left coordinates from the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: loc.x, y: primaryHeight - loc.y)
        let rules = settings.rules
        let at = Date()
        ax.async { [self] in
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.5)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let el = hit,
                  let app = AppInfo(pid: el.pid), app.bundleID != Bundle.main.bundleIdentifier else { return }
            guard let context = allowedContext(of: el, app, rules) else { return }
            let v = el.values([kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute])
            let role = v[kAXRoleAttribute] as? String
            var title = v[kAXTitleAttribute] as? String
            // Static text, links and cells carry their label as the value.
            // Text fields don't get theirs recorded on a click.
            if (title ?? "").isEmpty, let role, ["AXStaticText", "AXLink", "AXCell", "AXMenuItem", "AXButton"].contains(role) {
                title = (v[kAXValueAttribute] as? String).map { String($0.prefix(200)) }
            }
            let target = Target(role: role, subrole: v[kAXSubroleAttribute] as? String, title: title.map(Privacy.redactSecrets),
                                description: (v[kAXDescriptionAttribute] as? String).map(Privacy.redactSecrets))
            store.append(RecordedEvent(kind: .click, at: at, app: app.name, bundleID: app.bundleID, windowTitle: context.title, url: context.url, target: target))
        }
    }

    /// The window an element sits in, if it may be recorded.
    private func allowedContext(of el: AXUIElement, _ app: AppInfo, _ rules: PrivacyRules) -> (title: String?, url: String?)? {
        let win = el.element(kAXWindowAttribute) ?? AXUIElementCreateApplication(app.pid).element(kAXFocusedWindowAttribute)
        let title = win?.string(kAXTitleAttribute)
        let url = (win.map { w in lastWindow.flatMap { $0.pid == app.pid && $0.windowID == w.windowID ? $0.url : nil } }) ?? nil
        guard rules.allows(bundleID: app.bundleID, windowTitle: title, url: url) else {
            suppressed += 1
            return nil
        }
        return (title, url)
    }

    // MARK: Keys

    private func keyDown(_ e: NSEvent) {
        guard shouldRecord() else { return }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let isReturn = e.keyCode == 36 || e.keyCode == 76
        if isReturn && !mods.contains(.shift) && !mods.contains(.option) {
            submitted(at: Date())
        } else if mods.contains(.command) || mods.contains(.control) {
            shortcut(Self.describe(e, mods), at: Date())
        } else {
            // Typing: read the field a moment after Mike stops, so its
            // contents are known when Return sends and clears it.
            typingRead?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.ax.async { self?.readTyped() } }
            typingRead = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        return system.element(kAXFocusedUIElementAttribute)
    }

    private func readTyped() {
        guard let el = focusedElement() else { return }
        let v = el.values([kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute])
        guard v[kAXSubroleAttribute] as? String != "AXSecureTextField", let value = v[kAXValueAttribute] as? String else { return }
        // An emptied field (just sent) mustn't overwrite what it held a
        // moment ago, or Return would find nothing to record.
        if value.isEmpty, let t = typed, CFEqual(t.element, el) { return }
        typed = (el, value, Date())
    }

    private func submitted(at: Date) {
        typingRead?.cancel()
        let rules = settings.rules
        ax.async { [self] in
            guard let el = focusedElement(), let app = AppInfo(pid: el.pid), app.bundleID != Bundle.main.bundleIdentifier,
                  let context = allowedContext(of: el, app, rules) else { typed = nil; return }
            let v = el.values([kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute])
            let role = v[kAXRoleAttribute] as? String, subrole = v[kAXSubroleAttribute] as? String
            let title = v[kAXTitleAttribute] as? String, desc = v[kAXDescriptionAttribute] as? String
            let placeholder = el.string(kAXPlaceholderValueAttribute)
            // Chat boxes clear on Return before we get to look, so prefer what
            // the field held a moment ago, if it's the same field.
            var value = v[kAXValueAttribute] as? String
            if let t = typed, CFEqual(t.element, el), at.timeIntervalSince(t.at) < 120, !t.value.isEmpty { value = t.value }
            typed = nil
            let safe = Privacy.safeValue(value, role: role, subrole: subrole, labels: [title, desc, placeholder]).map { String($0.prefix(4_000)) }
            let target = Target(role: role, subrole: subrole, title: title, description: desc, placeholder: placeholder, value: safe)
            store.append(RecordedEvent(kind: .submit, at: at, app: app.name, bundleID: app.bundleID, windowTitle: context.title, url: context.url, target: target))
        }
    }

    private func shortcut(_ keys: String, at: Date) {
        let rules = settings.rules
        ax.async { [self] in
            guard let front = NSWorkspace.shared.frontmostApplication, let app = AppInfo(pid: front.processIdentifier),
                  app.bundleID != Bundle.main.bundleIdentifier, !rules.isExcludedApp(app.bundleID) else { return }
            let el = focusedElement()
            let context: (title: String?, url: String?)
            if let el {
                guard let allowed = allowedContext(of: el, app, rules) else { return }
                context = allowed
            } else {
                // No focused element means no window title to check, which
                // for a browser could be a private window.
                guard !Privacy.isBrowser(app.bundleID) else { return }
                context = (nil, nil)
            }
            let v = el?.values([kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute]) ?? [:]
            let target = Target(role: v[kAXRoleAttribute] as? String, title: v[kAXTitleAttribute] as? String, description: v[kAXDescriptionAttribute] as? String)
            store.append(RecordedEvent(kind: .shortcut, at: at, app: app.name, bundleID: app.bundleID, windowTitle: context.title, url: context.url, target: target, keys: keys))
        }
    }

    static func describe(_ e: NSEvent, _ mods: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.option) { parts.append("opt") }
        if mods.contains(.shift) { parts.append("shift") }
        if mods.contains(.command) { parts.append("cmd") }
        let named: [UInt16: String] = [36: "return", 76: "enter", 48: "tab", 49: "space", 51: "delete", 53: "escape",
                                       123: "left", 124: "right", 125: "down", 126: "up"]
        parts.append(named[e.keyCode] ?? (e.charactersIgnoringModifiers?.lowercased() ?? "?"))
        return parts.joined(separator: "+")
    }

    // MARK: System state

    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    static var screenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

struct AppInfo {
    let pid: pid_t
    let bundleID: String
    let name: String

    init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier ?? app.localizedName ?? "unknown"
        name = app.localizedName ?? bundleID
    }

    init?(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        self.init(app)
    }
}
