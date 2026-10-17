import AppKit
import Network

/// Restarts tunnels after sleep and pauses retries while offline (spec §5.2). Lives as long as the app.
@MainActor
final class SystemEvents {
    private let monitor = NWPathMonitor()
    private var wasSatisfied: Bool?

    init(store: TunnelStore) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak store] _ in
            Task { @MainActor in await store?.kickAll() }
        }

        monitor.pathUpdateHandler = { [weak self, weak store] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self, let store, self.wasSatisfied != satisfied else { return }
                let isChange = self.wasSatisfied != nil
                self.wasSatisfied = satisfied
                await store.setNetworkAvailable(satisfied)
                if satisfied, isChange { await store.kickAll() }
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }
}
