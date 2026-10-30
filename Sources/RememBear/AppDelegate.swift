import AppKit
import ApplicationServices
import RememBearCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private let store = EventStore()
    private lazy var recorder = Recorder(settings: settings, store: store)
    private lazy var summarizer = Summarizer(settings: settings, store: store)
    private lazy var setup = SetupWindowController()
    private var statusItem: NSStatusItem!
    private var iconTimer: Timer?
    /// The app that was in front when the menu opened. A menu bar app
    /// doesn't take focus, so this is the one Mike means by "this app".
    private var menuApp: AppInfo?
    private var menuSite: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensure()
        Log.info("started \(Bundle.main.bundleIdentifier ?? "?") pid \(getpid())")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        iconTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.updateIcon() }

        // The setup window asks for each permission and shows them going
        // green, rather than macOS's prompts all at once.
        if !Permissions.current().isComplete { setup.show() }
        if !settings.defaults.bool(forKey: "didRegisterLogin") {
            try? SMAppService.mainApp.register()
            settings.defaults.set(true, forKey: "didRegisterLogin")
        }
        recorder.start()
        summarizer.start()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.summarizer.kick()
        }
    }

    // Opening RememBear again (Spotlight, Finder) while it's running shows
    // its permissions, as a menu bar app has no window of its own to show.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setup.show()
        return false
    }

    private func updateIcon() {
        let symbol: String
        switch recorder.status {
        case .recording, .idle, .locked: symbol = "clock.arrow.circlepath"
        case .paused: symbol = "pause.circle"
        case .needsAccess, .needsScreenAccess: symbol = "exclamationmark.circle"
        }
        guard statusItem.button?.image?.accessibilityDescription != symbol else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            menuApp = AppInfo(front)
        }
        menuSite = recorder.frontURL.flatMap { $0.bundleID == menuApp?.bundleID ? Privacy.host(of: $0.url) : nil }

        let status = recorder.status
        switch status {
        case .recording: menu.addItem(disabled("Recording"))
        case .idle: menu.addItem(disabled("Recording (you're away)"))
        case .locked: menu.addItem(disabled("Recording (screen locked)"))
        case .paused(let until): menu.addItem(disabled("Paused until \(Self.time(until))"))
        case .needsScreenAccess: menu.addItem(disabled("Not recording yet"))
        case .needsAccess: menu.addItem(disabled("Recording windows"))
        }
        // Always there, so the permissions can be checked after a macOS
        // update or a rebuild quietly dropped one.
        let left = Permissions.current().remaining
        menu.addItem(item(left == 0 ? "Permissions…" : left == 1 ? "Finish Setting Up (1 left)…" : "Finish Setting Up (\(left) left)…", #selector(openSetup)))
        if let latest = summarizer.latest {
            let i = item("Last: \(latest.title)", #selector(openLatest))
            i.toolTip = latest.url.path
            menu.addItem(i)
        }
        if let error = summarizer.lastError {
            let i = disabled("Last summary failed")
            i.toolTip = error
            menu.addItem(i)
        }

        menu.addItem(.separator())
        if case .paused = status {
            menu.addItem(item("Resume", #selector(resume)))
        } else {
            menu.addItem(item("Pause for an Hour", #selector(pauseHour)))
            menu.addItem(item("Pause Until Tomorrow", #selector(pauseTomorrow)))
        }
        if let app = menuApp, !settings.rules.isExcludedApp(app.bundleID) {
            menu.addItem(item("Don't Record \(app.name)", #selector(excludeApp)))
        }
        if let site = menuSite {
            menu.addItem(item("Don't Record \(site)", #selector(excludeSite)))
        }
        let excluded = settings.excludedApps.map { ($0, Self.appName($0)) } + settings.excludedSites.map { ($0, $0) }
        if !excluded.isEmpty {
            let sub = NSMenu()
            for (key, name) in excluded {
                let i = item(name, #selector(unexclude(_:)))
                i.representedObject = key
                i.toolTip = "Click to record it again"
                sub.addItem(i)
            }
            let parent = NSMenuItem(title: "Not Recording", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(item("Forget the Last Hour", #selector(forgetHour)))

        menu.addItem(.separator())
        menu.addItem(item("Open Summaries Folder", #selector(openFolder)))
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit RememBear", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: Actions


    @objc private func openSetup() { setup.show() }

    @objc private func openLatest() {
        if let url = summarizer.latest?.url { NSWorkspace.shared.open(url) }
    }

    @objc private func resume() { settings.pausedUntil = nil; updateIcon(); Log.info("resumed") }

    @objc private func pauseHour() { pause(until: Date().addingTimeInterval(3600)) }

    @objc private func pauseTomorrow() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        pause(until: Calendar.current.date(byAdding: .hour, value: 6, to: tomorrow)!)
    }

    private func pause(until: Date) {
        settings.pausedUntil = until
        updateIcon()
        Log.info("paused until \(until)")
    }

    @objc private func excludeApp() {
        guard let app = menuApp else { return }
        settings.excludedApps.append(app.bundleID)
        Log.info("excluded app \(app.bundleID)")
    }

    @objc private func excludeSite() {
        guard let site = menuSite else { return }
        settings.excludedSites.append(site)
        Log.info("excluded site \(site)")
    }

    @objc private func unexclude(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        settings.excludedApps.removeAll { $0 == key }
        settings.excludedSites.removeAll { $0 == key }
        Log.info("recording \(key) again")
    }

    @objc private func forgetHour() {
        let alert = NSAlert()
        alert.messageText = "Forget the last hour?"
        alert.informativeText = "Deletes the recorded activity and summaries from the last hour, here and in Agent Archive."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        summarizer.forget(last: 3600)
    }

    @objc private func openFolder() { NSWorkspace.shared.open(Paths.summaries) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            Log.info("login item change failed: \(error)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
