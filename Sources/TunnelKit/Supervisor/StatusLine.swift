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
        case .custom: L10n.text("the server")
        }
    }

    public var methodName: String {
        switch method {
        case .ssh: "SSH"
        case .ssm: "AWS SSM"
        case .kubernetes: "Kubernetes"
        case .iap: "Google Cloud IAP"
        case .cloudflare: "Cloudflare Access"
        case .custom: L10n.text("Command")
        }
    }
}

/// The one-line status under a tunnel's name (spec §7).
public func statusLine(_ state: TunnelState, tunnel: Tunnel, now: Date) -> String {
    let port = String(tunnel.localPort)
    switch state {
    case .off:
        return L10n.text("Off")
    case .checking, .starting:
        return L10n.text("Connecting…")
    case .connected(let since):
        return L10n.text("Connected · \(duration(from: since, to: now))")
    case .retrying(let reason, _, _):
        return L10n.text("Reconnecting… \(retryReason(reason, tunnel: tunnel))")
    case .blocked(let owner):
        if let owner { return L10n.text("Port \(port) is in use by \(owner.command)") }
        return L10n.text("Port \(port) is in use")
    case .failed(let reason):
        return failureText(reason, tunnel: tunnel)
    case .standingBy:
        return L10n.text("Standing by · starts when an app connects")
    }
}

/// Full sentence for a failure, as in the spec §6 table.
public func failureText(_ reason: FailureReason, tunnel: Tunnel) -> String {
    let host = tunnel.remoteName
    let port = String(tunnel.localPort)
    switch reason {
    case .hostKeyChanged:
        return L10n.text("Host key changed for \(host). Check it, then remove the old key from known_hosts.")
    case .authFailed:
        return L10n.text("\(host) refused the key. Add it to the agent with ssh-add --apple-use-keychain.")
    case .ssoExpired(let profile):
        return L10n.text("AWS sign-in expired for profile \(profile ?? "default").")
    case .pluginMissing:
        return L10n.text("session-manager-plugin is not installed.")
    case .forwardRefused:
        return L10n.text("The server refused the forward.")
    case .hostUnreachable:
        return L10n.text("Can't reach \(host).")
    case .portInUse:
        return L10n.text("Port \(port) is in use.")
    case .toolMissing(let missing):
        return L10n.text("\(missing.tool) not found. Install it with \(missing.installHint).")
    case .readinessTimeout:
        return L10n.text("Port \(port) didn't open within 20 seconds.")
    case .stoppedResponding:
        return L10n.text("Stopped responding.")
    case .unknown(let status):
        return L10n.text("Exited (\(String(status))). See log.")
    }
}

private func retryReason(_ reason: FailureReason, tunnel: Tunnel) -> String {
    switch reason {
    case .hostUnreachable: L10n.text("can't reach \(tunnel.remoteName)")
    case .readinessTimeout: L10n.text("port didn't open")
    case .stoppedResponding: L10n.text("stopped responding")
    case .unknown(let status): L10n.text("exited (\(String(status)))")
    default: failureText(reason, tunnel: tunnel)
    }
}

private func duration(from start: Date, to end: Date) -> String {
    let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
    if minutes >= 60 { return L10n.text("\(String(minutes / 60))h \(String(minutes % 60))m") }
    if minutes >= 1 { return L10n.text("\(String(minutes))m") }
    return L10n.text("just now")
}
