import Foundation

/// Decides when to tell the user about a tunnel: down for a while, needing them, or back after
/// either. At most one notice per tunnel per change, so a tunnel retrying for an hour says so once.
public struct DropNotifier: Sendable {
    public enum Notice: Equatable, Sendable {
        /// Switched on but not connected for `downAfter`.
        case down
        /// Stopped on something only the user can fix (sign-in, host key, port taken…).
        case needsAction(TunnelState)
        /// Connected again after `down` or `needsAction`.
        case recovered
    }

    /// How long a tunnel may be reconnecting before it counts as down.
    public static let downAfter: TimeInterval = 30

    private struct Watch: Sendable {
        /// When it was last connected, standing by or switched on; nil while it is fine.
        var downSince: Date?
        var lastNotice: Notice?
    }

    private var watches: [UUID: Watch] = [:]

    public init() {}

    /// Records a state change; returns the notice to show now, if any.
    public mutating func update(_ id: UUID, state: TunnelState, now: Date) -> Notice? {
        var watch = watches[id] ?? Watch()
        defer { watches[id] = watch }
        switch state {
        case .off, .standingBy:
            // Switched off or idle on purpose: nothing to report, now or later.
            watch = Watch()
            return nil
        case .connected:
            let wasReported = watch.lastNotice != nil
            watch = Watch()
            return wasReported ? .recovered : nil
        case .blocked, .failed:
            if watch.downSince == nil { watch.downSince = now }
            return send(.needsAction(state), to: &watch)
        case .checking, .starting, .retrying:
            if watch.downSince == nil { watch.downSince = now }
            return nil
        }
    }

    /// Tunnels that have now been down for `downAfter` and haven't been reported yet.
    public mutating func check(now: Date) -> [(id: UUID, notice: Notice)] {
        var due: [(UUID, Notice)] = []
        for (id, var watch) in watches {
            guard let since = watch.downSince, watch.lastNotice == nil,
                  now.timeIntervalSince(since) >= Self.downAfter,
                  let notice = send(.down, to: &watch) else { continue }
            watches[id] = watch
            due.append((id, notice))
        }
        return due
    }

    public mutating func forget(_ id: UUID) {
        watches[id] = nil
    }

    private func send(_ notice: Notice, to watch: inout Watch) -> Notice? {
        guard watch.lastNotice != notice else { return nil }
        watch.lastNotice = notice
        return notice
    }
}
