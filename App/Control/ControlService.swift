import Foundation
import TunnelKit

/// control.sock in the data folder: the `portkeep` command line tool, and AI assistants through
/// `portkeep mcp`, drive the running app here. Every change goes through TunnelStore on the main
/// actor, as the editor's do, so the menu updates live and only this process writes tunnels.json.
@MainActor
final class ControlService {
    private var server: ControlSocketServer?

    func start(store: TunnelStore) {
        let router = ControlRouter(backend: store)
        let server = ControlSocketServer(path: ControlSocket.path(in: store.directory)) { line in
            await router.handle(line)
        }
        do {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try server.start()
            self.server = server
        } catch {
            NSLog("Portkeep: no control socket: %@", "\(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }
}

extension TunnelStore: ControlBackend {
    func discover() async -> Discovery {
        await Discovery.load(tools: tools)
    }
}
