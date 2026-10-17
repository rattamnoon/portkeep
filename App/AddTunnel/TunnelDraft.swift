import Foundation
import TunnelKit

enum MethodKind: String, CaseIterable, Identifiable {
    case ssh, ssm, kubernetes, iap, cloudflare, custom

    var id: Self { self }

    var title: String {
        switch self {
        case .ssh: "SSH"
        case .ssm: "AWS SSM"
        case .kubernetes: "Kubernetes"
        case .iap: "Google Cloud IAP"
        case .cloudflare: "Cloudflare Access"
        case .custom: String(localized: "Custom Command")
        }
    }

    var subtitle: String {
        switch self {
        case .ssh: "ssh -L / -R / -D"
        case .ssm: "aws ssm start-session"
        case .kubernetes: "kubectl port-forward"
        case .iap: "gcloud start-iap-tunnel"
        case .cloudflare: "cloudflared access tcp"
        case .custom: String(localized: "Any command that holds a port open")
        }
    }

    var needs: String {
        switch self {
        case .ssh: String(localized: "Uses /usr/bin/ssh with your ~/.ssh/config, keys and agent.")
        case .ssm: String(localized: "Needs the AWS CLI and session-manager-plugin.")
        case .kubernetes: String(localized: "Uses kubectl and your kubeconfig contexts.")
        case .iap: String(localized: "Needs the gcloud CLI, signed in.")
        case .cloudflare: String(localized: "Needs cloudflared. Signs in through the browser.")
        case .custom: String(localized: "Portkeep watches the port and restarts the command when it stops.")
        }
    }

    var symbol: String {
        switch self {
        case .ssh: "terminal"
        case .ssm: "cloud"
        case .kubernetes: "shippingbox"
        case .iap: "lock.shield"
        case .cloudflare: "globe"
        case .custom: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Everything the Add/Edit form can hold, as strings, so half-typed values survive switching methods.
struct TunnelDraft: Equatable {
    var id = UUID()
    var name = ""
    var group = "Other"
    var localPort = ""
    var connectAtLogin = false
    /// Comma-separated, as typed.
    var tags = ""
    var kind: MethodKind = .ssh

    var sshMode: SSHMode = .local
    var sshHost = ""
    var sshJump = ""
    var destHost = ""
    var destPort = ""
    var identityFile = ""
    var keepAlive = "30"
    var exitOnForwardFailure = true
    var compression = false
    var extraArgs = ""

    var profile = "default"
    var region = ""
    var target = ""
    var ssmToRemoteHost = true
    var remoteHost = ""
    var remotePort = ""
    var ssoAutoLogin = true

    var context = ""
    var namespace = "default"
    var resource = ""

    var project = ""
    var zone = ""
    var instance = ""

    var hostname = ""
    var command = ""

    init() {}

    init(_ tunnel: Tunnel) {
        id = tunnel.id
        name = tunnel.name
        group = tunnel.group
        localPort = String(tunnel.localPort)
        connectAtLogin = tunnel.connectAtLogin
        tags = tunnel.tags.joined(separator: ", ")
        switch tunnel.method {
        case .ssh(let c):
            kind = .ssh
            sshMode = c.mode; sshHost = c.host; sshJump = c.jump ?? ""
            destHost = c.destination?.host ?? ""; destPort = c.destination.map { String($0.port) } ?? ""
            identityFile = c.identityFile ?? ""; keepAlive = String(c.keepAlive)
            exitOnForwardFailure = c.exitOnForwardFailure; compression = c.compression; extraArgs = c.extraArgs
        case .ssm(let c):
            kind = .ssm
            profile = c.profile; region = c.region; target = c.target; ssoAutoLogin = c.ssoAutoLogin
            switch c.forwardTo {
            case .remoteHost(let e): ssmToRemoteHost = true; remoteHost = e.host; remotePort = String(e.port)
            case .instance(let port): ssmToRemoteHost = false; remotePort = String(port)
            }
        case .kubernetes(let c):
            kind = .kubernetes
            context = c.context; namespace = c.namespace; resource = c.resource; remotePort = String(c.remotePort)
        case .iap(let c):
            kind = .iap
            project = c.project; zone = c.zone; instance = c.instance; remotePort = String(c.remotePort)
        case .cloudflare(let c):
            kind = .cloudflare
            hostname = c.hostname
        case .custom(let c):
            kind = .custom
            command = c.command
        }
    }

    private func port(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else { return nil }
        return value
    }

    private func filled(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    var method: TunnelMethod? {
        switch kind {
        case .ssh:
            guard let host = filled(sshHost) else { return nil }
            var destination: Endpoint?
            if sshMode != .dynamic {
                guard let dh = filled(destHost), let dp = port(destPort) else { return nil }
                destination = Endpoint(host: dh, port: dp)
            }
            return .ssh(SSHConfig(
                mode: sshMode, host: host, jump: filled(sshJump), destination: destination,
                identityFile: filled(identityFile), keepAlive: Int(keepAlive) ?? 30,
                exitOnForwardFailure: exitOnForwardFailure, compression: compression, extraArgs: extraArgs))
        case .ssm:
            guard let profile = filled(profile), let region = filled(region), let target = filled(target),
                  let rp = port(remotePort) else { return nil }
            let forward: SSMForward
            if ssmToRemoteHost {
                guard let rh = filled(remoteHost) else { return nil }
                forward = .remoteHost(Endpoint(host: rh, port: rp))
            } else {
                forward = .instance(port: rp)
            }
            return .ssm(SSMConfig(profile: profile, region: region, target: target, forwardTo: forward, ssoAutoLogin: ssoAutoLogin))
        case .kubernetes:
            guard let c = filled(context), let n = filled(namespace), let r = filled(resource), let rp = port(remotePort) else { return nil }
            return .kubernetes(KubeConfig(context: c, namespace: n, resource: r, remotePort: rp))
        case .iap:
            guard let p = filled(project), let z = filled(zone), let i = filled(instance), let rp = port(remotePort) else { return nil }
            return .iap(IAPConfig(project: p, zone: z, instance: i, remotePort: rp))
        case .cloudflare:
            guard let h = filled(hostname) else { return nil }
            return .cloudflare(CloudflareConfig(hostname: h))
        case .custom:
            guard let c = filled(command) else { return nil }
            return .custom(CustomConfig(command: c))
        }
    }

    /// Nil until every required field is filled with a valid value.
    var tunnel: Tunnel? {
        guard let name = filled(name), let local = port(localPort), let method else { return nil }
        return Tunnel(id: id, name: name, group: filled(group) ?? "Other", localPort: local,
                      connectAtLogin: connectAtLogin, method: method, tags: Tunnel.parseTags(tags))
    }
}
