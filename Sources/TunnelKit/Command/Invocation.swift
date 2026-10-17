import Foundation

/// An executable plus argv. Never a shell string, except for the Custom method (ADR-0002).
public struct Invocation: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct ToolMissing: Error, Hashable, Sendable {
    public let tool: String
    public let installHint: String

    public init(tool: String, installHint: String) {
        self.tool = tool
        self.installHint = installHint
    }
}

public enum CommandBuilder {
    static let installHints = [
        "ssh": "brew install openssh",
        "aws": "brew install awscli",
        "session-manager-plugin": "brew install --cask session-manager-plugin",
        "kubectl": "brew install kubectl",
        "gcloud": "brew install --cask google-cloud-sdk",
        "cloudflared": "brew install cloudflared",
    ]

    /// Every tool the method needs on disk; the first is the one that gets launched.
    public static func requiredTools(for method: TunnelMethod) -> [String] {
        switch method {
        case .ssh: ["ssh"]
        case .ssm: ["aws", "session-manager-plugin"]
        case .kubernetes: ["kubectl"]
        case .iap: ["gcloud"]
        case .cloudflare: ["cloudflared"]
        case .custom: []
        }
    }

    public static func invocation(for tunnel: Tunnel, tools: ToolPaths) throws(ToolMissing) -> Invocation {
        let required = requiredTools(for: tunnel.method)
        var urls: [URL] = []
        for tool in required {
            guard let url = tools.url(for: tool) else {
                throw ToolMissing(tool: tool, installHint: installHints[tool] ?? "")
            }
            urls.append(url)
        }
        let l = tunnel.localPort

        switch tunnel.method {
        case .ssh(let c):
            var a = ["-N"]
            switch c.mode {
            case .local: a += ["-L", "\(l):\(c.destination?.host ?? "localhost"):\(c.destination?.port ?? l)"]
            case .remote: a += ["-R", "\(l):\(c.destination?.host ?? "localhost"):\(c.destination?.port ?? l)"]
            case .dynamic: a += ["-D", "\(l)"]
            }
            if let jump = c.jump, !jump.isEmpty { a += ["-J", jump] }
            if c.exitOnForwardFailure { a += ["-o", "ExitOnForwardFailure=yes"] }
            a += ["-o", "ServerAliveInterval=\(c.keepAlive)", "-o", "BatchMode=yes"]
            if let identity = c.identityFile, !identity.isEmpty {
                a += ["-i", (identity as NSString).expandingTildeInPath]
            }
            if c.compression { a.append("-C") }
            a += shellSplit(c.extraArgs)
            a.append(c.host)
            return Invocation(executable: urls[0], arguments: a)

        case .ssm(let c):
            let (document, parameters): (String, String) = switch c.forwardTo {
            case .remoteHost(let e):
                ("AWS-StartPortForwardingSessionToRemoteHost", "host=\(e.host),portNumber=\(e.port),localPortNumber=\(l)")
            case .instance(let port):
                ("AWS-StartPortForwardingSession", "portNumber=\(port),localPortNumber=\(l)")
            }
            return Invocation(executable: urls[0], arguments: [
                "ssm", "start-session", "--profile", c.profile, "--region", c.region, "--target", c.target,
                "--document-name", document, "--parameters", parameters,
            ])

        case .kubernetes(let c):
            return Invocation(executable: urls[0], arguments: [
                "--context", c.context, "-n", c.namespace, "port-forward", c.resource,
                "\(l):\(c.remotePort)", "--address", "127.0.0.1",
            ])

        case .iap(let c):
            return Invocation(executable: urls[0], arguments: [
                "compute", "start-iap-tunnel", c.instance, "\(c.remotePort)",
                "--local-host-port=localhost:\(l)", "--zone", c.zone, "--project", c.project,
            ])

        case .cloudflare(let c):
            return Invocation(executable: urls[0], arguments: [
                "access", "tcp", "--hostname", c.hostname, "--url", "localhost:\(l)",
            ])

        case .custom(let c):
            return Invocation(
                executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-c", c.command.replacingOccurrences(of: "{port}", with: "\(l)")])
        }
    }

    /// Splits like a POSIX shell for quoting only: no variables, globs or substitutions.
    static func shellSplit(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false

        for ch in text {
            if escaped {
                current.append(ch); escaped = false; inWord = true
            } else if ch == "\\" && quote != "'" {
                escaped = true; inWord = true
            } else if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch; inWord = true
            } else if ch.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
            } else {
                current.append(ch); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
