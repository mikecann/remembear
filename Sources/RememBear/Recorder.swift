import AppKit
import ApplicationServices
import RememBearCore
import ScreenCaptureKit
import Vision

/// Watches what Mike does: the window in front and the text on it, Return
/// in a text field and keyboard shortcuts. The text comes from a screenshot
/// of that one window, read by on-device text recognition and then thrown
/// away; the image is never written down.
///
/// Until 30 Oct 2026 it read windows through the Accessibility API, walking
/// each one's tree and asking what was under every click. That made each
/// app it read do the work on its own main thread: Threadbear took half a
/// second to switch views, and Chrome and Electron apps had to keep their
/// whole accessibility tree built. A screenshot comes from the window server
/// and costs the app nothing. Accessibility is still needed, but only for
/// the global key monitor.
///
/// Every privacy check happens before a window is captured, and again after,
/// so nothing from an excluded app, an excluded site or a private window is
/// ever written down.
final class Recorder {
    enum Status: Equatable {
        case recording, paused(until: Date), needsScreenAccess, needsAccess, idle, locked
    }

    private let settings: Settings
    private let store: EventStore
    private var timer: Timer?
    private var monitors: [Any] = []
    private var trusted = false

    private var lastKey: String?
    private var pendingKey: String?
    private var lastLines = Set<String>()
    private var lastSnapshot = Date.distantPast
    /// Return was pressed: look again a moment later, when what was sent
    /// shows in the window.
    private var lookAgainAt: Date?
    private var capturing = false
    /// The last capture's fingerprint, for the window `lastKey` names. A
    /// reread that matches it is dropped before any text is read.
    private var lastFingerprint: [UInt8]?
    private(set) var unchangedSkips = 0
    private var loggedScriptError = Set<String>()

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

    static var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    var status: Status {
        if !Self.hasScreenAccess { return .needsScreenAccess }
        if !AXIsProcessTrusted() { return .needsAccess }
        if let until = settings.pausedUntil, until > Date() { return .paused(until: until) }
        if Self.screenLocked { return .locked }
        if Self.idleSeconds > idleAfter { return .idle }
        return .recording
    }

    // Windows are still recorded without Accessibility; only Return and
    // shortcuts need it.
    private func shouldRecord() -> Bool { status == .recording || status == .needsAccess }

    // Key monitors only deliver once the app is trusted, so they're
    // (re)installed when trust is granted.
    private func refreshTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted || monitors.isEmpty else { return }
        trusted = now
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in self?.keyDown(e) }) { monitors.append(m) }
        Log.info("accessibility \(now ? "granted" : "not granted"); key monitor installed")
    }

    // MARK: The window in front

    private struct Front {
        let app: AppInfo
        let window: WindowList.Window
        let url: String?
    }

    /// The frontmost app's front window, if it may be recorded right now.
    /// Browsers are asked over AppleScript whether the window is private,
    /// as its title doesn't say (`PrivacyRules.allowsBrowser`).
    private func allowedFront() -> Front? {
        guard let running = NSWorkspace.shared.frontmostApplication,
              running.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let app = AppInfo(running)
        let rules = settings.rules
        if rules.isExcludedApp(app.bundleID) { return nil }
        guard let window = WindowList.front(of: app.pid) else { return nil }
        if Privacy.isBrowser(app.bundleID) {
            let script = Privacy.isChromium(app.bundleID) ? frontBrowserWindow(app.bundleID) : nil
            guard rules.allowsBrowser(bundleID: app.bundleID, windowListTitle: window.title, script: script) else { return nil }
            return Front(app: app, window: window, url: script?.url)
        }
        guard rules.allows(bundleID: app.bundleID, windowTitle: window.title, url: nil) else { return nil }
        return Front(app: app, window: window, url: nil)
    }

    // MARK: Polling

    private func tick() {
        refreshTrust()
        guard shouldRecord(), !capturing, let running = NSWorkspace.shared.frontmostApplication,
              running.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let app = AppInfo(running)
        if settings.rules.isExcludedApp(app.bundleID) { skip(); return }
        guard let window = WindowList.front(of: app.pid) else { return }

        // Cheap: from the window list, no AppleScript or capture yet.
        let key = "\(app.bundleID)|\(window.id)|\(window.title ?? "")"
        let now = Date()
        let changed = key != lastKey
        let lookAgain = lookAgainAt.map { now >= $0 } ?? false
        if changed {
            // Wait for the same window on two ticks in a row, so loading
            // titles and windows flicked past don't count.
            guard key == pendingKey else { pendingKey = key; return }
        } else if !lookAgain, now.timeIntervalSince(lastSnapshot) < snapshotEvery || Self.idleSeconds > snapshotEvery {
            return
        }
        lookAgainAt = nil

        guard let front = allowedFront(), front.window.id == window.id, front.window.title == window.title else {
            suppressed += 1
            lastKey = key
            lastLines = []
            frontURL = nil
            return
        }
        frontURL = front.url.map { (front.app.bundleID, $0) }
        lastSnapshot = now
        capturing = true
        // Background priority: a plain Task here inherits the main thread's
        // user-initiated priority, and Vision's accurate recognition then
        // spread over the performance cores (296% CPU while Mike was working,
        // 30 Oct 2026). History can wait a moment; Mike's apps can't.
        // A new window is always read. A reread of the same one only is if
        // it looks different from last time.
        let previous = changed ? nil : lastFingerprint
        Task(priority: .background) { [self] in
            let read = await ScreenReader.read(windowID: window.id, unlessSameAs: previous)
            await MainActor.run { finish(front, key: key, changed: changed, read: read, at: now) }
        }
    }

    private func finish(_ front: Front, key: String, changed: Bool, read: ScreenReader.Result?, at: Date) {
        capturing = false
        guard let read else { return }
        let lines: [String], image: CGImage
        switch read {
        case .unchanged:
            unchangedSkips += 1
            return
        case .read(let l, let i, let fingerprint):
            lines = l
            image = i
            lastFingerprint = fingerprint
        }
        // The same window must still be in front, under the same title and
        // still allowed, or what was captured might be from a window that
        // went private or got excluded while it was being read.
        guard let again = allowedFront(), again.app.pid == front.app.pid, again.window.id == front.window.id,
              again.window.title == front.window.title else {
            suppressed += 1
            Log.info("dropped a capture: the window changed while it was read")
            return
        }
        let raw = lines.joined(separator: "\n")
        // A page that has just made a key is left out whole: a new key can
        // be any shape, and masking only knows the common ones.
        if Privacy.looksLikeKeyBeingShown(raw) || Privacy.looksLikeKeyBeingShown(front.window.title ?? "") {
            suppressed += 1
            Log.info("skipped a window that looked like it was showing a key")
            return
        }
        var text = Privacy.redactScreenText(raw)
        if text.count > maxText { text = String(text.prefix(maxText)) }
        let shown = text.split(whereSeparator: \.isNewline).map(String.init)
        let title = front.window.title.map(Privacy.redactScreenText)
        if changed {
            lastKey = key
            lastLines = Set(shown)
            store.append(RecordedEvent(kind: .windowChanged, at: at, app: front.app.name, bundleID: front.app.bundleID,
                                       windowTitle: title, url: front.url, text: text.isEmpty ? nil : text))
        } else {
            let fresh = shown.filter { !lastLines.contains($0) }
            lastLines = Set(shown)
            guard !fresh.isEmpty else { return }
            store.append(RecordedEvent(kind: .snapshot, at: at, app: front.app.name, bundleID: front.app.bundleID,
                                       windowTitle: title, url: front.url, text: fresh.joined(separator: "\n")))
        }
        // Only what was recorded gets a vector, after the same privacy
        // checks, so search never holds anything the events wouldn't.
        let shot = (app: front.app.name, bundleID: front.app.bundleID, title: title, url: front.url, excerpt: ScreenSearch.excerpt(of: text))
        Task.detached(priority: .background) {
            guard let vector = await Embedder.shared.embed(image: image) else { return }
            ShotStore.shared.add(ScreenSearch.Shot(at: at, app: shot.app, bundleID: shot.bundleID, title: shot.title,
                                                   url: shot.url, excerpt: shot.excerpt, vector: vector))
        }
    }

    private func skip() {
        suppressed += 1
        lastKey = nil
        pendingKey = nil
        frontURL = nil
    }

    // MARK: Browsers

    /// The browser's front window over AppleScript: its mode (normal or
    /// incognito), title and URL. Nil when it can't be asked, which leaves
    /// the window out. The first time, macOS asks Mike to let RememBear
    /// control the browser.
    private func frontBrowserWindow(_ bundleID: String) -> BrowserWindow? {
        let source = """
        tell application id "\(bundleID)"
            with timeout of 2 seconds
                set w to front window
                return {mode of w, title of w, URL of active tab of w}
            end timeout
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), result.numberOfItems == 3 else {
            if !loggedScriptError.contains(bundleID) {
                loggedScriptError.insert(bundleID)
                Log.info("can't ask \(bundleID) about its window, so it isn't recorded: \(error?[NSAppleScript.errorMessage] ?? "no answer")")
            }
            return nil
        }
        return BrowserWindow(mode: result.atIndex(1)?.stringValue, title: result.atIndex(2)?.stringValue, url: result.atIndex(3)?.stringValue)
    }

    // MARK: Keys

    private func keyDown(_ e: NSEvent) {
        guard shouldRecord() else { return }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let isReturn = e.keyCode == 36 || e.keyCode == 76
        if isReturn && !mods.contains(.shift) && !mods.contains(.option) {
            record(.submit, keys: nil)
            // What was sent shows in the window a moment later.
            lookAgainAt = Date().addingTimeInterval(1.5)
        } else if mods.contains(.command) || mods.contains(.control) {
            record(.shortcut, keys: Self.describe(e, mods))
        }
    }

    private func record(_ kind: RecordedEvent.Kind, keys: String?) {
        guard let front = allowedFront() else { return }
        store.append(RecordedEvent(kind: kind, at: Date(), app: front.app.name, bundleID: front.app.bundleID,
                                   windowTitle: front.window.title.map(Privacy.redactScreenText), url: front.url, keys: keys))
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

/// Windows as the window server lists them, front to back. Titles need
/// Screen Recording access; without it they're nil.
enum WindowList {
    struct Window: Equatable {
        let id: CGWindowID
        let title: String?
    }

    /// The app's frontmost ordinary window: on screen, at the normal level,
    /// and big enough to be a window rather than a tooltip or a badge.
    static func front(of pid: pid_t) -> Window? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Double],
                  (bounds["Width"] ?? 0) >= 160, (bounds["Height"] ?? 0) >= 100,
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Window(id: id, title: title)
        }
        return nil
    }
}

/// Takes one window's picture and reads the text on it, on the Mac. The
/// image stays in memory: it's read here, embedded for search, then gone.
enum ScreenReader {
    /// The longest side of the picture, in pixels: plenty for reading text,
    /// and it keeps a big window's recognition well under a second.
    static let maxSide = 3_000.0

    enum Result {
        /// Looked the same as `unlessSameAs`, so no text was read.
        case unchanged
        /// The window's text lines, its picture for the embedder (kept in
        /// memory only) and its fingerprint for next time.
        case read(lines: [String], image: CGImage, fingerprint: [UInt8])
    }

    static func read(windowID: CGWindowID, unlessSameAs previous: [UInt8]?) async -> Result? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = Double(filter.pointPixelScale)
            let size = window.frame.size
            let shrink = min(1, maxSide / (max(size.width, size.height) * scale))
            config.width = max(1, Int(size.width * scale * shrink))
            config.height = max(1, Int(size.height * scale * shrink))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let fingerprint = Self.fingerprint(image)
            if let fingerprint, Fingerprint.isSame(previous, fingerprint) { return .unchanged }
            return .read(lines: try recognize(image), image: image, fingerprint: fingerprint ?? [])
        } catch {
            Log.info("couldn't read window \(windowID): \(error.localizedDescription)")
            return nil
        }
    }

    /// The picture shrunk to a small grey square (`Fingerprint.side`).
    static func fingerprint(_ image: CGImage) -> [UInt8]? {
        let side = Fingerprint.side
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }

    private static func recognize(_ image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // English only: guessing the language on every read costs time, and
        // Mike's screens are English.
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let pieces = (request.results ?? []).compactMap { o -> RememBearCore.RecognizedText? in
            guard let text = o.topCandidates(1).first?.string else { return nil }
            // Vision's boxes are 0...1 from the bottom left.
            let b = o.boundingBox
            return RememBearCore.RecognizedText(text: text, x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }
        return ScreenText.lines(pieces)
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
