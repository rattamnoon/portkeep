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
    /// Free-form labels for filtering, e.g. "db", "readonly". Colours live in `TunnelFile.tagColors`.
    public var tags: [String]

    public init(
        id: UUID = UUID(), name: String, group: String, localPort: Int,
        connectAtLogin: Bool = false, method: TunnelMethod, tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.localPort = localPort
        self.connectAtLogin = connectAtLogin
        self.method = method
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey { case id, name, group, localPort, connectAtLogin, method, tags }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        group = try c.decode(String.self, forKey: .group)
        localPort = try c.decode(Int.self, forKey: .localPort)
        connectAtLogin = try c.decodeIfPresent(Bool.self, forKey: .connectAtLogin) ?? false
        method = try c.decode(TunnelMethod.self, forKey: .method)
        // Files written before tags existed have none.
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

/// Colours for tags and groups. Any colour can be chosen; it is stored as "#RRGGBB".
public enum LabelColor {
    /// Starting colours, one picked per name so a new tag or group has a colour before anyone chooses.
    public static let presets = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#007AFF", "#5856D6", "#AF52DE", "#FF2D55", "#8E8E93"]

    public static func defaultHex(for name: String) -> String {
        let sum = name.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return presets[sum % presets.count]
    }

    /// (red, green, blue) in 0...1, or nil when `hex` isn't "#RRGGBB" / "RRGGBB".
    public static func components(_ hex: String) -> (Double, Double, Double)? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    public static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

extension Tunnel {
    /// Splits "db, readonly ,db" into ["db", "readonly"]: trimmed, de-duplicated, order kept.
    public static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
