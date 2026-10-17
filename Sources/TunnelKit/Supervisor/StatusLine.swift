import Foundation

extension Tunnel {
    /// The host a person would name for this tunnel, used in status and failure text.
    public var remoteName: String {
        switch method {
        case .ssh(let c): c.host
        case .ssm(let c): c.target
        case .kubernetes(let c): c.context
        case .iap(let c): c.instance
        case .cloudflare(let c): c.hostname
        case .custom: "the server"
        }
    }

    public var methodName: String {
        switch method {
        case .ssh: "SSH"
        case .ssm: "AWS SSM"
        case .kubernetes: "Kubernetes"
        case .iap: "Google Cloud IAP"
        case .cloudflare: "Cloudflare Access"
        case .custom: "Command"
        }
    }
}

/// The one-line status under a tunnel's name (spec §7).
public func statusLine(_ state: TunnelState, tunnel: Tunnel, now: Date, blockedBy: String? = nil) -> String {
    switch state {
    case .off:
        return "Off"
    case .checking, .starting:
        return "Connecting…"
    case .connected(let since):
        return "Connected · \(duration(from: since, to: now))"
    case .retrying(let reason, _, _):
        return "Reconnecting… \(retryReason(reason, tunnel: tunnel))"
    case .blocked(let owner):
        if let blockedBy { return "Port \(tunnel.localPort) is used by \(blockedBy)" }
        if let owner { return "Port \(tunnel.localPort) is in use by \(owner.command)" }
        return "Port \(tunnel.localPort) is in use"
    case .failed(let reason):
        return failureText(reason, tunnel: tunnel)
    }
}

/// Full sentence for a failure, as in the spec §6 table.
public func failureText(_ reason: FailureReason, tunnel: Tunnel) -> String {
    let host = tunnel.remoteName
    switch reason {
    case .hostKeyChanged:
        return "Host key changed for \(host). Check it, then remove the old key from known_hosts."
    case .authFailed:
        return "\(host) refused the key. Add it to the agent with ssh-add --apple-use-keychain."
    case .ssoExpired(let profile):
        return "AWS sign-in expired for profile \(profile ?? "default")."
    case .pluginMissing:
        return "session-manager-plugin is not installed."
    case .forwardRefused:
        return "The server refused the forward."
    case .hostUnreachable:
        return "Can't reach \(host)."
    case .portInUse:
        return "Port \(tunnel.localPort) is in use."
    case .toolMissing(let missing):
        return "\(missing.tool) not found. Install it with \(missing.installHint)."
    case .readinessTimeout:
        return "Port \(tunnel.localPort) didn't open within 20 seconds."
    case .stoppedResponding:
        return "Stopped responding."
    case .unknown(let status):
        return "Exited (\(status)). See log."
    }
}

private func retryReason(_ reason: FailureReason, tunnel: Tunnel) -> String {
    switch reason {
    case .hostUnreachable: "can't reach \(tunnel.remoteName)"
    case .readinessTimeout: "port didn't open"
    case .stoppedResponding: "stopped responding"
    case .unknown(let status): "exited (\(status))"
    default: failureText(reason, tunnel: tunnel)
    }
}

private func duration(from start: Date, to end: Date) -> String {
    let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
    if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
    if minutes >= 1 { return "\(minutes)m" }
    return "just now"
}
