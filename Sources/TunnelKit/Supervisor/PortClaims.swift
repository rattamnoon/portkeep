import Foundation

/// Which tunnel owns each local port, so two tunnels on one port never both run (spec §5.4).
/// Tunnels may share a port on purpose (Production and Development MySQL both on 3306): switching
/// one on switches the other off.
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

    public struct SwitchOn: Equatable, Sendable {
        /// Tunnels to start, in list order.
        public var start: [UUID]
        /// Tunnels outside the set that hold a port one of `start` needs; stop these first.
        public var stop: [UUID]

        public init(start: [UUID], stop: [UUID]) {
            self.start = start
            self.stop = stop
        }
    }

    /// What switching on `tunnels` (in list order) together does, one tunnel per local port.
    /// A port already held by one of them stays with it; otherwise the first one on the port takes it,
    /// stopping whichever other tunnel holds it. The rest sharing that port stay off.
    public func planSwitchOn(_ tunnels: [Tunnel]) -> SwitchOn {
        var decided = Set(tunnels.filter { holders[$0.localPort] == $0.id }.map(\.localPort))
        var plan = SwitchOn(start: [], stop: [])
        for tunnel in tunnels where decided.insert(tunnel.localPort).inserted {
            if let holder = holders[tunnel.localPort], !plan.stop.contains(holder) { plan.stop.append(holder) }
            plan.start.append(tunnel.id)
        }
        return plan
    }
}
