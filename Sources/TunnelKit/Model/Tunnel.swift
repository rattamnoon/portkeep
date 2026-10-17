import Foundation

public struct Endpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public enum SSHMode: String, Codable, Hashable, Sendable {
    case local, remote, dynamic
}

public struct SSHConfig: Codable, Hashable, Sendable {
    public var mode: SSHMode
    public var host: String
    public var jump: String?
    public var destination: Endpoint?
    public var identityFile: String?
    public var keepAlive: Int
    public var exitOnForwardFailure: Bool
    public var compression: Bool
    public var extraArgs: String

    public init(
        mode: SSHMode, host: String, jump: String? = nil, destination: Endpoint? = nil,
        identityFile: String? = nil, keepAlive: Int = 30, exitOnForwardFailure: Bool = true,
        compression: Bool = false, extraArgs: String = ""
    ) {
        self.mode = mode
        self.host = host
        self.jump = jump
        self.destination = destination
        self.identityFile = identityFile
        self.keepAlive = keepAlive
        self.exitOnForwardFailure = exitOnForwardFailure
        self.compression = compression
        self.extraArgs = extraArgs
    }
}

public enum SSMForward: Codable, Hashable, Sendable {
    case remoteHost(Endpoint)
    case instance(port: Int)

    private enum CodingKeys: String, CodingKey { case remoteHost, instance }
    private struct InstancePort: Codable { var port: Int }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let endpoint = try c.decodeIfPresent(Endpoint.self, forKey: .remoteHost) {
            self = .remoteHost(endpoint)
        } else if let target = try c.decodeIfPresent(InstancePort.self, forKey: .instance) {
            self = .instance(port: target.port)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath, debugDescription: "forwardTo needs remoteHost or instance"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .remoteHost(let endpoint): try c.encode(endpoint, forKey: .remoteHost)
        case .instance(let port): try c.encode(InstancePort(port: port), forKey: .instance)
        }
    }
}

public struct SSMConfig: Codable, Hashable, Sendable {
    public var profile: String
    public var region: String
    public var target: String
    public var forwardTo: SSMForward
    public var ssoAutoLogin: Bool

    public init(profile: String, region: String, target: String, forwardTo: SSMForward, ssoAutoLogin: Bool = true) {
        self.profile = profile
        self.region = region
        self.target = target
        self.forwardTo = forwardTo
        self.ssoAutoLogin = ssoAutoLogin
    }
}

public struct KubeConfig: Codable, Hashable, Sendable {
    public var context: String
    public var namespace: String
    public var resource: String
    public var remotePort: Int

    public init(context: String, namespace: String, resource: String, remotePort: Int) {
        self.context = context
        self.namespace = namespace
        self.resource = resource
        self.remotePort = remotePort
    }
}

public struct IAPConfig: Codable, Hashable, Sendable {
    public var project: String
    public var zone: String
    public var instance: String
    public var remotePort: Int

    public init(project: String, zone: String, instance: String, remotePort: Int) {
        self.project = project
        self.zone = zone
        self.instance = instance
        self.remotePort = remotePort
    }
}

public struct CloudflareConfig: Codable, Hashable, Sendable {
    public var hostname: String

    public init(hostname: String) {
        self.hostname = hostname
    }
}

public struct CustomConfig: Codable, Hashable, Sendable {
    public var command: String

    public init(command: String) {
        self.command = command
    }
}

/// How a tunnel is opened. Encoded as a single-key object, e.g. `{"ssm": {…}}`.
public enum TunnelMethod: Codable, Hashable, Sendable {
    case ssh(SSHConfig)
    case ssm(SSMConfig)
    case kubernetes(KubeConfig)
    case iap(IAPConfig)
    case cloudflare(CloudflareConfig)
    case custom(CustomConfig)

    private enum CodingKeys: String, CodingKey { case ssh, ssm, kubernetes, iap, cloudflare, custom }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = c.allKeys.first, c.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath, debugDescription: "method must have exactly one key"))
        }
        switch key {
        case .ssh: self = .ssh(try c.decode(SSHConfig.self, forKey: key))
        case .ssm: self = .ssm(try c.decode(SSMConfig.self, forKey: key))
        case .kubernetes: self = .kubernetes(try c.decode(KubeConfig.self, forKey: key))
        case .iap: self = .iap(try c.decode(IAPConfig.self, forKey: key))
        case .cloudflare: self = .cloudflare(try c.decode(CloudflareConfig.self, forKey: key))
        case .custom: self = .custom(try c.decode(CustomConfig.self, forKey: key))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ssh(let v): try c.encode(v, forKey: .ssh)
        case .ssm(let v): try c.encode(v, forKey: .ssm)
        case .kubernetes(let v): try c.encode(v, forKey: .kubernetes)
        case .iap(let v): try c.encode(v, forKey: .iap)
        case .cloudflare(let v): try c.encode(v, forKey: .cloudflare)
        case .custom(let v): try c.encode(v, forKey: .custom)
        }
    }
}

public struct Tunnel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var group: String
    public var localPort: Int
    public var connectAtLogin: Bool
    public var method: TunnelMethod

    public init(
        id: UUID = UUID(), name: String, group: String, localPort: Int,
        connectAtLogin: Bool = false, method: TunnelMethod
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.localPort = localPort
        self.connectAtLogin = connectAtLogin
        self.method = method
    }
}
