import AppKit
import ApplicationServices
import RememBearCore
import SwiftUI

/// Reads where each permission stands, and asks for them.
enum Permissions {
    static let chromeID = "com.google.Chrome"

    static func current() -> SetupState {
        SetupState(screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .missing,
                   accessibility: AXIsProcessTrusted() ? .granted : .missing,
                   chrome: chrome(ask: false))
    }

    /// Whether RememBear may ask Chrome about its windows over AppleScript.
    /// With `ask`, macOS shows its "RememBear wants to control Google Chrome"
    /// prompt if it hasn't been answered yet; that blocks until Mike picks,
    /// so it's only called off the main thread.
    static func chrome(ask: Bool) -> PermissionState {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeID) != nil else { return .notNeeded }
        let target = NSAppleEventDescriptor(bundleIdentifier: chromeID)
        guard let desc = target.aeDesc else { return .missing }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .waitingForApp
        default: return .missing
        }
    }

    static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

/// Keeps the window's state fresh: macOS sends no notice when a permission
/// is switched on, so it looks again every second while the window is open.
final class SetupModel: ObservableObject {
    @Published var state = Permissions.current()
    /// Screen Recording often only takes once RememBear restarts.
    @Published var askedForScreen = false
    private var timer: Timer?

    func start() {
        refresh()
        // Scheduled on the main run loop, so it refreshes on the main thread.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let now = Permissions.current()
        if now != state { state = now }
    }

    func allowScreen() {
        askedForScreen = true
        // The first time this shows macOS's own prompt; after that it does
        // nothing, so the Settings pane opens too.
        CGRequestScreenCaptureAccess()
        Permissions.openSettings("Privacy_ScreenCapture")
    }

    func allowAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        Permissions.openSettings("Privacy_Accessibility")
    }

    func allowChrome() {
        switch state.chrome {
        case .waitingForApp:
            NSWorkspace.shared.openApplication(at: NSWorkspace.shared.urlForApplication(withBundleIdentifier: Permissions.chromeID)!,
                                               configuration: NSWorkspace.OpenConfiguration())
        case .denied:
            Permissions.openSettings("Privacy_Automation")
        default:
            DispatchQueue.global().async { _ = Permissions.chrome(ask: true) }
        }
    }

    /// Opens a new copy once this one has quit, so a Screen Recording grant
    /// takes.
    func restart() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    let close: () -> Void

    var body: some View {
        let s = model.state
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.isComplete ? "RememBear is all set" : "Let RememBear remember")
                        .font(.title3.weight(.semibold))
                    Text(s.isComplete ? "You can close this." : "Each one turns green once it's on.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                PermissionRow(state: s.screenRecording, title: "Screen Recording",
                              why: "Reads the window in front. The picture never leaves this Mac.",
                              button: "Open Settings", action: model.allowScreen)
                Divider()
                PermissionRow(state: s.accessibility, title: "Accessibility",
                              why: "Notices Return and shortcuts. Never reads other apps' windows.",
                              button: "Open Settings", action: model.allowAccessibility)
                if s.chrome != .notNeeded {
                    Divider()
                    PermissionRow(state: s.chrome, title: "Control Chrome",
                                  why: "Asks Chrome whether a window is incognito, so those are never recorded.",
                                  button: chromeButton(s.chrome), action: model.allowChrome)
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                if model.askedForScreen && s.screenRecording != .granted {
                    Button("Restart RememBear", action: model.restart)
                        .help("Screen Recording often only takes after a restart")
                }
                Spacer()
                Button(s.isComplete ? "Done" : "Later", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func chromeButton(_ state: PermissionState) -> String {
        switch state {
        case .waitingForApp: "Open Chrome"
        case .denied: "Open Settings"
        default: "Allow"
        }
    }
}

private struct PermissionRow: View {
    let state: PermissionState
    let title: String
    let why: String
    let button: String
    let action: () -> Void

    var body: some View {
        let on = state == .granted
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(on ? Color.green : Color.red)
                .frame(width: 11, height: 11)
                .animation(.easeOut(duration: 0.25), value: on)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if on {
                Image(systemName: "checkmark").foregroundStyle(.green).font(.body.weight(.semibold))
            } else {
                Button(button, action: action)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// The setup window. A menu bar app has no Dock icon to bring it back, so
/// the menu has "Finish Setting Up…" while anything's missing.
final class SetupWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = SetupModel()

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SetupView(model: model) { [weak self] in self?.window?.close() })
            let w = NSWindow(contentViewController: host)
            w.title = "RememBear"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        model.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var windowNumber: Int? { window?.windowNumber }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}
