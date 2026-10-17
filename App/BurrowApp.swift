import SwiftUI
import TunnelKit

@main
struct BurrowApp: App {
    var body: some Scene {
        MenuBarExtra("Burrow", systemImage: "point.3.connected.trianglepath.dotted") {
            Button("Quit Burrow") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
