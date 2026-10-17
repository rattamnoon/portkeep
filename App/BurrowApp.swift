import SwiftUI
import TunnelKit

@main
struct BurrowApp: App {
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

        WindowGroup("Log", id: "log", for: UUID.self) { $id in
            LogView(id: id)
                .environment(delegate.store)
        }
        .defaultSize(width: 640, height: 420)
    }
}

/// Which tunnel the Settings window shows, and whether the Add sheet is open.
@MainActor @Observable
final class Navigation {
    var selection: SettingsSelection?
    var showingAdd = false
}

enum SettingsSelection: Hashable {
    case tunnel(UUID)
    case tools
    case general
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: TunnelStore
    let navigation = Navigation()
    private var events: SystemEvents?
    private var previewWindows: [NSWindow] = []
    private let environment = ProcessInfo.processInfo.environment

    override init() {
        // BURROW_DATA_DIR points the app at another folder (development and screenshots).
        store = environment["BURROW_DATA_DIR"].map { TunnelStore(directory: URL(fileURLWithPath: $0)) } ?? TunnelStore()
        super.init()
    }

    private var termSource: DispatchSourceSignal?

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

        if environment["BURROW_DEMO"] == "1" {
            store.loadDemo()
        } else {
            events = SystemEvents(store: store)
            Task { await store.start() }
        }
        if let show = environment["BURROW_SHOW"] { showPreview(show) }
    }

    /// Opens a view in an ordinary window so it can be captured with `screencapture -l`.
    /// Writes the window number to `$BURROW_DATA_DIR/window-<name>.txt`.
    private func showPreview(_ names: String) {
        for name in names.split(separator: ",").map(String.init) {
            let view: AnyView
            switch name {
            case "menu":
                view = AnyView(MenuView().environment(store).environment(navigation)
                    .background(.regularMaterial))
            case "settings":
                navigation.selection = store.tunnels.dropFirst(2).first.map { .tunnel($0.id) }
                view = AnyView(SettingsView().environment(store).environment(navigation).frame(width: 820, height: 640))
            case "add":
                view = AnyView(AddTunnelView().environment(store))
            default:
                continue
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Burrow"
            if name == "menu" { window.styleMask = [.borderless]; window.hasShadow = true }
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            // Always on the menu-bar screen, so captures and UI tests find it. After ordering front:
            // with "Displays have separate Spaces" AppKit moves new windows to the active display.
            // SwiftUI sizes the window after the first layout pass, so place it once that has happened.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let screen = NSScreen.screens.first?.visibleFrame else { return }
                window.setFrameOrigin(NSPoint(x: screen.midX - window.frame.width / 2,
                                              y: screen.midY - window.frame.height / 2))
            }
            previewWindows.append(window)
            if let dir = environment["BURROW_DATA_DIR"] {
                try? "\(window.windowNumber)".write(toFile: "\(dir)/window-\(name).txt", atomically: true, encoding: .utf8)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop every child before exiting so no ssh/aws process outlives the app. Synchronous on
        // purpose: with .terminateLater AppKit spins a modal run loop where our async work never ran.
        store.stopAllNow()
        return .terminateNow
    }
}
