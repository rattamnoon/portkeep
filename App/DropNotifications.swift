import Foundation
import TunnelKit
import UserNotifications

/// macOS notifications when a tunnel has been down for a while, needs the user, or is back
/// (Settings › General). `DropNotifier` decides when; this posts them.
@MainActor
final class DropNotifications {
    /// Settings › General: "Notify when a tunnel drops". On unless switched off.
    static var enabled: Bool {
        // bool(forKey:) also reads "NO" from the command line (UI tests).
        UserDefaults.standard.object(forKey: "notifyOnDrop") == nil || UserDefaults.standard.bool(forKey: "notifyOnDrop")
    }

    /// Name, local port and current status line of a tunnel, or nil once it's gone.
    var lookup: (UUID) -> (name: String, port: Int, status: String)? = { _ in nil }
    private var notifier = DropNotifier()

    func stateChanged(_ id: UUID, to state: TunnelState) {
        if let notice = notifier.update(id, state: state, now: .now) { post(notice, for: id) }
        switch state {
        case .checking, .starting, .retrying:
            // Look again once it could count as down.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(DropNotifier.downAfter + 0.5))
                self?.postDue()
            }
        default:
            break
        }
    }

    func forget(_ id: UUID) {
        notifier.forget(id)
    }

    private func postDue() {
        for (id, notice) in notifier.check(now: .now) { post(notice, for: id) }
    }

    private func post(_ notice: DropNotifier.Notice, for id: UUID) {
        guard Self.enabled, let tunnel = lookup(id) else { return }
        let content = UNMutableNotificationContent()
        switch notice {
        case .down:
            content.title = String(localized: "\(tunnel.name) is down")
            content.body = tunnel.status
        case .needsAction:
            content.title = String(localized: "\(tunnel.name) needs attention")
            content.body = tunnel.status
        case .recovered:
            content.title = String(localized: "\(tunnel.name) is back")
            content.body = String(localized: "Connected on 127.0.0.1:\(String(tunnel.port)).")
        }
        if notice != .recovered { content.sound = .default }
        // One per tunnel: "is back" replaces "is down" in Notification Center.
        let request = UNNotificationRequest(identifier: "tunnel-\(id.uuidString)", content: content, trigger: nil)
        Task {
            guard await Self.authorize() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Asks once, the first time a notification would be sent or the setting is switched on.
    @discardableResult
    static func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    static var isDenied: Bool {
        get async { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied }
    }
}
