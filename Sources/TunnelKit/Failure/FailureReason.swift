public enum FailureReason: Equatable, Hashable, Sendable {
    case hostKeyChanged
    case authFailed
    case ssoExpired(profile: String?)
    case pluginMissing
    case forwardRefused
    case hostUnreachable
    case portInUse
    case toolMissing(ToolMissing)
    case readinessTimeout
    /// Was Connected, then two health probes in a row failed.
    case stoppedResponding
    case unknown(status: Int32)

    /// Only failures that can clear up on their own are retried (spec §6).
    public var isRetryable: Bool {
        switch self {
        case .hostUnreachable, .readinessTimeout, .stoppedResponding, .unknown: true
        default: false
        }
    }
}

public enum FailureClassifier {
    /// Table order is priority order: the first row whose pattern appears anywhere wins.
    private static let table: [(patterns: [String], reason: @Sendable (String?) -> FailureReason)] = [
        (["remote host identification has changed"], { _ in .hostKeyChanged }),
        (["permission denied ("], { _ in .authFailed }),
        (["token has expired",
          "sso session associated with this profile has expired",
          "error when retrieving token from sso"], { .ssoExpired(profile: $0) }),
        (["sessionmanagerplugin is not found"], { _ in .pluginMissing }),
        (["remote port forwarding failed", "administratively prohibited"], { _ in .forwardRefused }),
        (["could not resolve hostname", "connection timed out", "no route to host",
          "network is unreachable", "connection refused"], { _ in .hostUnreachable }),
        (["address already in use"], { _ in .portInUse }),
    ]

    public static func classify(stderr: [String], status: Int32, profile: String?) -> FailureReason {
        let text = stderr.joined(separator: "\n").lowercased()
        for row in table where row.patterns.contains(where: text.contains) {
            return row.reason(profile)
        }
        return .unknown(status: status)
    }
}
