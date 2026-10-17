import SwiftUI
import TunnelKit
import UserNotifications

@main
struct PortkeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(delegate.store)
                .environment(delegate.navigation)
        } label: {
            MenuBarLabel(connected: delegate.store.connectedCount, attention: delegate.store.needsAttention)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(delegate.store)
                .environment(delegate.navigation)
        }

        Window("Add Tunnel", id: "add") {
            AddTunnelView()
                .environment(delegate.store)
                .environment(delegate.navigation)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        WindowGroup("Log", id: "log", for: UUID.self) { $id in
            LogView(id: id)
                .environment(delegate.store)
        }
        .defaultSize(width: 640, height: 420)
    }
}

/// Which item the Settings window shows.
@MainActor @Observable
final class Navigation {
    var selection: SettingsSelection?
    /// Opens (or brings forward) the one Settings window.
    @ObservationIgnored var showSettings: () -> Void = {}
}

enum SettingsSelection: Hashable {
    case tunnel(UUID)
    case tools
    case general
    case labels
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store: TunnelStore
    let navigation = Navigation()
    private var events: SystemEvents?
    private var previewWindows: [NSWindow] = []
    private let environment = ProcessInfo.processInfo.environment

    override init() {
        // PORTKEEP_DATA_DIR points the app at another folder (development and screenshots).
        store = environment["PORTKEEP_DATA_DIR"].map { TunnelStore(directory: URL(fileURLWithPath: $0)) } ?? TunnelStore()
        super.init()
    }

    private var termSource: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // portkeep:// URLs (the command line tool). Taken here, before SwiftUI, which would open a
        // window for each one.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), let command = RemoteCommand(url: url) else { return }
        switch command {
        case .run(let action, let target):
            Task { await store.perform(action, on: target) }
        case .openSettings(let name):
            if let name, let tunnel = RemoteCommand.Target.tunnel(name).tunnels(in: store.tunnels).first {
                navigation.selection = .tunnel(tunnel.id)
            }
            showSettings()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill`/launchd send SIGTERM, which would skip applicationShouldTerminate and orphan children.
        // Unblock it too: a parent shell can hand us a mask with SIGTERM blocked.
        var term = sigset_t()
        sigemptyset(&term)
        sigaddset(&term, SIGTERM)
        pthread_sigmask(SIG_UNBLOCK, &term, nil)
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { NSApplication.shared.terminate(nil) }
        termSource?.resume()
        AppActivation.observeWindowCloses()

        switch environment["PORTKEEP_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

        navigation.showSettings = { [weak self] in self?.showSettings() }

        if environment["PORTKEEP_DEMO"] == "1" {
            store.loadDemo()
        } else {
            UNUserNotificationCenter.current().delegate = self
            events = SystemEvents(store: store)
            Task {
                await store.start()
                // First launch: nothing in the menu bar says much yet, so show where to start.
                if store.tunnels.isEmpty, environment["PORTKEEP_SHOW"] == nil { showSettings() }
            }
        }
        if let show = environment["PORTKEEP_SHOW"] { showPreview(show) }
    }

    private var settingsWindow: NSWindow?

    /// The Settings window. Opening the app again (Finder, Dock, `open`) shows it, since a
    /// menu bar app otherwise gives no sign that it is running, and the icon can sit under the notch.
    func showSettings() {
        AppActivation.bringForward()
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        if navigation.selection == nil, let first = store.tunnels.first { navigation.selection = .tunnel(first.id) }
        let hosting = NSHostingController(rootView: SettingsView().environment(store).environment(navigation))
        // Only enforce the minimum; otherwise the split view's ideal size grows the window to the screen.
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentViewController = hosting
        // Sidebar runs up under the title bar, as in System Settings.
        window.toolbar = NSToolbar(identifier: "settings")
        window.toolbarStyle = .unified
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        let restored = window.setFrameUsingName("PortkeepSettings")
        window.setFrameAutosaveName("PortkeepSettings")
        window.makeKeyAndOrderFront(nil)
        if !restored {
            // After the first layout pass: SwiftUI sizes the window to the split view's ideal size,
            // which is the whole screen.
            DispatchQueue.main.async {
                window.setContentSize(NSSize(width: 860, height: 640))
                window.center()
            }
        }
        settingsWindow = window
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Opens a view in an ordinary window so it can be captured with `screencapture -l`.
    /// Writes the window number to `$PORTKEEP_DATA_DIR/window-<name>.txt`.
    private func showPreview(_ names: String) {
        AppActivation.bringForward()
        for name in names.split(separator: ",").map(String.init) {
            let view: AnyView
            switch name {
            case "menu":
                view = AnyView(MenuView().environment(store).environment(navigation)
                    .background(.regularMaterial))
            case "settings":
                navigation.selection = store.tunnels.dropFirst(2).first.map { .tunnel($0.id) }
                view = AnyView(SettingsView().environment(store).environment(navigation).frame(width: 820, height: 640))
            case "labels":
                navigation.selection = .labels
                view = AnyView(SettingsView().environment(store).environment(navigation).frame(width: 820, height: 640))
            case "add":
                view = AnyView(AddTunnelView().environment(store).environment(navigation))
            default:
                continue
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Portkeep"
            if name == "menu" { window.styleMask = [.borderless]; window.hasShadow = true }
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            // Top-left of its screen and no larger than it: CI runners have small displays, and a
            // control past the screen edge can't be clicked by UI tests.
            if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                var frame = window.frame
                frame.size.width = min(frame.width, visible.width)
                frame.size.height = min(frame.height, visible.height)
                frame.origin = NSPoint(x: visible.minX, y: visible.maxY - frame.height)
                window.setFrame(frame, display: true)
            }
            previewWindows.append(window)
            if let dir = environment["PORTKEEP_DATA_DIR"] {
                try? "\(window.windowNumber)".write(toFile: "\(dir)/window-\(name).txt", atomically: true, encoding: .utf8)
            }
        }
        AppActivation.bringForward()
    }

    /// Show tunnel notifications even while one of our windows is in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop every child before exiting so no ssh/aws process outlives the app. Synchronous on
        // purpose: with .terminateLater AppKit spins a modal run loop where our async work never ran.
        store.stopAllNow()
        return .terminateNow
    }
}
