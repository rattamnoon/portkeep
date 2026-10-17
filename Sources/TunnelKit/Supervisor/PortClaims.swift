import Foundation

/// Which tunnel owns each local port, so two tunnels on one port never both run (spec §5.4).
public struct PortClaims: Sendable {
    private var holders: [Int: UUID] = [:]

    public init() {}

    /// Claims `port` for `tunnel`. Returns the other tunnel holding it, or nil when the claim succeeded.
    public mutating func claim(_ port: Int, by tunnel: UUID) -> UUID? {
        if let holder = holders[port], holder != tunnel { return holder }
        holders[port] = tunnel
        return nil
    }

    public mutating func release(_ port: Int, by tunnel: UUID) {
        if holders[port] == tunnel { holders[port] = nil }
    }

    public func holder(of port: Int) -> UUID? { holders[port] }

    public enum Start: Equatable, Sendable {
        case start
        case blocked(by: UUID)
    }

    /// Claims ports for every tunnel set to connect at login, in file order: the first tunnel on a
    /// port starts, later ones are blocked by it.
    public mutating func planLogin(_ tunnels: [Tunnel]) -> [(id: UUID, start: Start)] {
        tunnels.filter(\.connectAtLogin).map { tunnel in
            if let holder = claim(tunnel.localPort, by: tunnel.id) {
                return (tunnel.id, .blocked(by: holder))
            }
            return (tunnel.id, .start)
        }
    }
}
