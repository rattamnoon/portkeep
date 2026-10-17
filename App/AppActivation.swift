import AppKit

/// A menu bar–only app can't reliably take focus on macOS 14+: its windows open behind other apps
/// and don't receive typing. While any of our windows is open we become a regular app (Dock icon,
/// key windows), and go back to menu bar–only when the last one closes.
@MainActor
enum AppActivation {
    static func bringForward() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    /// Call when a window is about to close.
    static func windowWillClose(_ closing: NSWindow) {
        let others = NSApp.windows.filter {
            $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    static func observeWindowCloses() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { windowWillClose(window) }
        }
    }
}
