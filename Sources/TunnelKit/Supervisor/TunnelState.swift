import Foundation

/// The states of spec §5.1.
public enum TunnelState: Equatable, Hashable, Sendable {
    case off
    case checking
    /// The local port is taken; `owner` is the process holding it when known.
    case blocked(PortOwner?)
    case starting
    case connected(since: Date)
    case retrying(FailureReason, attempt: Int, until: Date)
    case failed(FailureReason)
    /// On demand and idle: Portkeep listens on the local port; the tunnel starts when an app connects.
    case standingBy

    /// Shown with a dot on the menu bar item.
    public var needsAttention: Bool {
        switch self {
        case .blocked, .retrying, .failed: true
        default: false
        }
    }

    public var isOn: Bool { self != .off }
}
