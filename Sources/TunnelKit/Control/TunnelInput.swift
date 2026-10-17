import Foundation

/// Tunnels from JSON an agent or script sent, and the rules every saved tunnel follows. The editor's
/// form (TunnelDraft) checks its result with `validate` too, so both paths accept the same tunnels.
public enum TunnelInput {
    /// The one-key objects in a tunnel: a patch naming another key replaces the object.
    static let unions: Set<String> = ["method", "method.ssm.forwardTo"]

    /// A new tunnel: tunnels.json's shape without `id`, defaults filled in. `file` is checked for a
    /// tunnel with the same name.
    public static func newTunnel(from json: JSONValue, in file: TunnelFile) throws(RPCError) -> Tunnel {
        guard json.objectValue != nil else { throw .invalid("A tunnel is a JSON object with name, localPort and method.") }
        var merged = MethodCatalog.tunnelDefaults.merging(json, unions: unions)
        if case .object(var object) = merged {
            object["id"] = .string(UUID().uuidString)
            merged = .object(object)
        }
        return try finish(merged, original: json, in: file, id: nil)
    }

    /// `tunnel` with `patch` applied (JSON merge patch: only the fields to change, `null` removes one).
    public static func updated(_ tunnel: Tunnel, patch: JSONValue, in file: TunnelFile) throws(RPCError) -> Tunnel {
        guard patch.objectValue != nil else { throw .invalid("A patch is a JSON object of the fields to change.") }
        if let id = patch["id"]?.stringValue, UUID(uuidString: id) != tunnel.id {
            throw .invalid("A tunnel's id can't change.", field: "id")
        }
        guard let base = try? JSONValue(encoding: tunnel) else { throw RPCError(RPCError.internalError, "Couldn’t read the tunnel.") }
        return try finish(base.merging(patch, unions: unions), original: patch, in: file, id: tunnel.id)
    }

    private static func finish(_ merged: JSONValue, original: JSONValue, in file: TunnelFile, id: UUID?) throws(RPCError) -> Tunnel {
        if let key = MethodCatalog.unknownKey(in: original) {
            throw .invalid("Unknown field \(key). See methods.describe for the fields each method takes.", field: key)
        }
        var merged = merged
        // A method's own defaults (ssh mode, AWS profile, namespace…) under what was sent.
        if case .object(var object) = merged, let method = object["method"]?.objectValue {
            guard method.count == 1, let entry = method.first else {
                throw .invalid("method needs exactly one key: ssh, ssm, kubernetes, iap, cloudflare or custom.", field: "method")
            }
            let (key, config) = (entry.key, entry.value)
            guard MethodCatalog.method(key) != nil else {
                throw .invalid("Unknown method \(key). Use ssh, ssm, kubernetes, iap, cloudflare or custom.", field: "method")
            }
            object["method"] = .object([key: MethodCatalog.defaults(for: key).merging(config)])
            merged = .object(object)
        }
        for field in MethodCatalog.tunnelFields where field.required && merged[field.name] == nil {
            throw .invalid("\(field.name) is required.", field: field.name)
        }
        let tunnel: Tunnel
        do {
            tunnel = try merged.decode(as: Tunnel.self)
        } catch let error as DecodingError {
            throw describe(error)
        } catch {
            throw .invalid("\(error)")
        }
        let valid = try validate(tunnel)
        if let other = file.tunnels.first(where: {
            $0.id != valid.id && $0.name.caseInsensitiveCompare(valid.name) == .orderedSame
        }) {
            throw RPCError(RPCError.conflict,
                           "A tunnel named \(other.name) already exists (id \(other.id.uuidString)). Pick another name, or update that one.",
                           data: .object(["field": .string("name"), "id": .string(other.id.uuidString)]))
        }
        return valid
    }

    /// The rules a tunnel must follow to be saved, with whitespace trimmed and empty optionals removed.
    public static func validate(_ tunnel: Tunnel) throws(RPCError) -> Tunnel {
        var t = tunnel
        t.name = t.name.trimmingCharacters(in: .whitespaces)
        guard !t.name.isEmpty else { throw .invalid("name can’t be empty.", field: "name") }
        t.group = t.group.trimmingCharacters(in: .whitespaces)
        if t.group.isEmpty { t.group = "Other" }
        try port(t.localPort, "localPort")
        t.tags = Tunnel.parseTags(t.tags.joined(separator: ","))
        guard t.tags.count <= 1 else { throw .invalid("A tunnel has at most one tag.", field: "tags") }
        guard t.idleMinutes >= 0 else { throw .invalid("idleMinutes can’t be negative.", field: "idleMinutes") }

        switch t.method {
        case .ssh(var c):
            c.host = try filled(c.host, "method.ssh.host")
            c.jump = optional(c.jump)
            c.identityFile = optional(c.identityFile)
            if c.mode == .dynamic {
                c.destination = nil
            } else {
                guard var d = c.destination else {
                    throw .invalid("SSH \(c.mode.rawValue) forwarding needs destination {host, port}.", field: "method.ssh.destination")
                }
                d.host = try filled(d.host, "method.ssh.destination.host")
                try port(d.port, "method.ssh.destination.port")
                c.destination = d
            }
            guard c.keepAlive >= 0 else { throw .invalid("keepAlive can’t be negative.", field: "method.ssh.keepAlive") }
            t.method = .ssh(c)
        case .ssm(var c):
            c.profile = try filled(c.profile, "method.ssm.profile")
            c.region = try filled(c.region, "method.ssm.region")
            c.target = try filled(c.target, "method.ssm.target")
            switch c.forwardTo {
            case .remoteHost(var e):
                e.host = try filled(e.host, "method.ssm.forwardTo.remoteHost.host")
                try port(e.port, "method.ssm.forwardTo.remoteHost.port")
                c.forwardTo = .remoteHost(e)
            case .instance(let p):
                try port(p, "method.ssm.forwardTo.instance.port")
            }
            t.method = .ssm(c)
        case .kubernetes(var c):
            c.context = try filled(c.context, "method.kubernetes.context")
            c.namespace = try filled(c.namespace, "method.kubernetes.namespace")
            c.resource = try filled(c.resource, "method.kubernetes.resource")
            try port(c.remotePort, "method.kubernetes.remotePort")
            t.method = .kubernetes(c)
        case .iap(var c):
            c.project = try filled(c.project, "method.iap.project")
            c.zone = try filled(c.zone, "method.iap.zone")
            c.instance = try filled(c.instance, "method.iap.instance")
            try port(c.remotePort, "method.iap.remotePort")
            t.method = .iap(c)
        case .cloudflare(var c):
            c.hostname = try filled(c.hostname, "method.cloudflare.hostname")
            t.method = .cloudflare(c)
        case .custom(var c):
            c.command = try filled(c.command, "method.custom.command")
            t.method = .custom(c)
        }
        if t.startsOnConnect, !t.supportsOnDemand {
            throw .invalid("startsOnConnect isn’t available for SSH remote forwarding, or for a custom command without {port}.",
                           field: "startsOnConnect")
        }
        return t
    }

    private static func port(_ value: Int, _ field: String) throws(RPCError) {
        guard (1...65535).contains(value) else { throw .invalid("\(field) must be a port from 1 to 65535.", field: field) }
    }

    private static func filled(_ text: String, _ field: String) throws(RPCError) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .invalid("\(field) can’t be empty.", field: field) }
        return trimmed
    }

    private static func optional(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "method.ssm.region is required." rather than Foundation's coding-path dump.
    static func describe(_ error: DecodingError) -> RPCError {
        func path(_ context: DecodingError.Context, _ key: CodingKey? = nil) -> String {
            (context.codingPath + (key.map { [$0] } ?? [])).map { $0.intValue.map(String.init) ?? $0.stringValue }
                .joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            let field = path(context, key)
            return .invalid("\(field) is required.", field: field)
        case .typeMismatch(let type, let context), .valueNotFound(let type, let context):
            let field = path(context)
            let expected = type == Int.self ? "a whole number" : type == Bool.self ? "true or false"
                : type == String.self ? "a string" : "\(type)"
            return .invalid("\(field) should be \(expected).", field: field)
        case .dataCorrupted(let context):
            let field = path(context)
            return .invalid(field.isEmpty ? context.debugDescription : "\(field): \(context.debugDescription)", field: field)
        @unknown default:
            return .invalid("\(error)")
        }
    }
}
