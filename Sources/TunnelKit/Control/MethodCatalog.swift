import Foundation

/// What each connection method's fields mean, with defaults and an example tunnel: what
/// `methods.describe` returns and what the MCP tools' input schemas are built from, so an agent can
/// fill a tunnel in correctly. English only; it is read by programs.
public enum MethodCatalog {
    public struct Field: Sendable {
        public var name: String
        /// JSON Schema type: string, integer, boolean, array, object.
        public var type: String
        public var required: Bool
        public var defaultValue: JSONValue?
        public var description: String
        public var choices: [String]?
        /// For objects: their fields.
        public var fields: [Field]?

        init(_ name: String, _ type: String, required: Bool = false, default defaultValue: JSONValue? = nil,
             choices: [String]? = nil, fields: [Field]? = nil, _ description: String) {
            self.name = name
            self.type = type
            self.required = required
            self.defaultValue = defaultValue
            self.description = description
            self.choices = choices
            self.fields = fields
        }
    }

    public struct Method: Sendable {
        public var key: String
        public var title: String
        public var runs: String
        public var tools: [String]
        public var summary: String
        public var fields: [Field]
        public var example: JSONValue
    }

    private static func endpoint(_ what: String) -> [Field] {
        [
            Field("host", "string", required: true, "Host name or IP \(what)."),
            Field("port", "integer", required: true, "Port on that host, 1–65535."),
        ]
    }

    /// Fields every tunnel has, whatever the method.
    public static let tunnelFields: [Field] = [
        Field("name", "string", required: true,
              "Shown in the menu bar and used to address the tunnel (portkeep start <name>). Must be unique, ignoring case."),
        Field("group", "string", default: .string("Other"),
              "Environment or project heading, e.g. Production, Staging, Development. Created if new."),
        Field("localPort", "integer", required: true,
              "Port on 127.0.0.1 that apps connect to (for SSH remote mode, the port opened on the server). 1–65535. Tunnels may share a port: switching one on switches the other off."),
        Field("method", "object", required: true,
              "How to connect: an object with exactly one key, one of ssh, ssm, kubernetes, iap, cloudflare, custom. See methods."),
        Field("tags", "array", default: .array([]), "At most one label, e.g. [\"db\"]."),
        Field("connectAtLogin", "boolean", default: .bool(false),
              "Start this tunnel when Portkeep opens at login."),
        Field("startsOnConnect", "boolean", default: .bool(false),
              "On demand: Portkeep listens on localPort and starts the tunnel when an app connects. Not for SSH remote mode, nor a custom command without {port}."),
        Field("idleMinutes", "integer", default: .int(Tunnel.defaultIdleMinutes),
              "With startsOnConnect, stop after this many minutes without connections; 0 keeps it running."),
    ]

    public static let methods: [Method] = [
        Method(
            key: "ssh", title: "SSH", runs: "ssh -N -L/-R/-D … host", tools: ["ssh"],
            summary: "Forward through an SSH server, optionally via a jump host (ProxyJump). Uses ~/.ssh/config, keys and ssh-agent; never prompts for a password (BatchMode).",
            fields: [
                Field("mode", "string", default: .string("local"), choices: ["local", "remote", "dynamic"],
                      "local = -L (localPort on this Mac → destination via host), remote = -R (localPort on the server → destination from this Mac), dynamic = -D (SOCKS proxy on localPort; no destination)."),
                Field("host", "string", required: true,
                      "SSH host: an alias from ~/.ssh/config (see discover) or user@hostname."),
                Field("jump", "string", "Jump host for ProxyJump (-J), e.g. bastion or user@bastion:22. Omit for none."),
                Field("destination", "object", fields: endpoint("as seen from the SSH host"),
                      "Required for local and remote mode: where connections end up, e.g. {\"host\": \"db.internal\", \"port\": 3306}."),
                Field("identityFile", "string", "Private key path, e.g. ~/.ssh/id_ed25519. Omit to use ssh-agent and ~/.ssh/config."),
                Field("keepAlive", "integer", default: .int(30), "ServerAliveInterval in seconds."),
                Field("exitOnForwardFailure", "boolean", default: .bool(true),
                      "Fail instead of staying connected when the port can't be forwarded."),
                Field("compression", "boolean", default: .bool(false), "ssh -C."),
                Field("extraArgs", "string", default: .string(""), "More ssh arguments, e.g. -o LogLevel=ERROR."),
            ],
            example: .object([
                "name": .string("Orders MySQL"), "group": .string("Staging"), "localPort": .int(3306),
                "tags": .array([.string("db")]),
                "method": .object(["ssh": .object([
                    "mode": .string("local"), "host": .string("app-server"), "jump": .string("bastion"),
                    "destination": .object(["host": .string("mysql.internal"), "port": .int(3306)]),
                ])]),
            ])),
        Method(
            key: "ssm", title: "AWS SSM", runs: "aws ssm start-session --document-name AWS-StartPortForwardingSession…", tools: ["aws", "session-manager-plugin"],
            summary: "AWS Systems Manager port forwarding through an EC2 instance: to a port on the instance, or to another host the instance can reach (RDS, ElastiCache…). No SSH keys or open inbound ports needed.",
            fields: [
                Field("profile", "string", default: .string("default"), "AWS profile from ~/.aws/config (see discover)."),
                Field("region", "string", required: true, "AWS region, e.g. ap-southeast-1. discover shows each profile's region."),
                Field("target", "string", required: true, "EC2 instance ID running the SSM agent, e.g. i-0123456789abcdef0."),
                Field("forwardTo", "object", required: true, fields: [
                    Field("remoteHost", "object", fields: endpoint("the instance can reach, e.g. an RDS endpoint"),
                          "Forward to another host through the instance."),
                    Field("instance", "object", fields: [Field("port", "integer", required: true, "Port on the instance.")],
                          "Forward to a port on the instance itself."),
                ], "Exactly one of {\"remoteHost\": {\"host\": …, \"port\": …}} or {\"instance\": {\"port\": …}}."),
                Field("ssoAutoLogin", "boolean", default: .bool(true),
                      "Offer AWS SSO sign-in in the app when the session expires."),
            ],
            example: .object([
                "name": .string("Prod MySQL"), "group": .string("Production"), "localPort": .int(3307),
                "tags": .array([.string("db")]),
                "method": .object(["ssm": .object([
                    "profile": .string("prod"), "region": .string("ap-southeast-1"), "target": .string("i-0a3f5c9e2b7d41f08"),
                    "forwardTo": .object(["remoteHost": .object([
                        "host": .string("orders.cluster-ro.abc123.ap-southeast-1.rds.amazonaws.com"), "port": .int(3306),
                    ])]),
                ])]),
            ])),
        Method(
            key: "kubernetes", title: "Kubernetes", runs: "kubectl --context … -n … port-forward <resource> local:remote", tools: ["kubectl"],
            summary: "kubectl port-forward to a service, pod or deployment, bound to 127.0.0.1.",
            fields: [
                Field("context", "string", required: true, "kubeconfig context (see discover)."),
                Field("namespace", "string", default: .string("default"), "Namespace."),
                Field("resource", "string", required: true, "svc/<name>, pod/<name> or deploy/<name>."),
                Field("remotePort", "integer", required: true, "Port on the resource."),
            ],
            example: .object([
                "name": .string("Grafana"), "group": .string("Production"), "localPort": .int(3000),
                "method": .object(["kubernetes": .object([
                    "context": .string("prod"), "namespace": .string("monitoring"),
                    "resource": .string("svc/grafana"), "remotePort": .int(3000),
                ])]),
            ])),
        Method(
            key: "iap", title: "Google Cloud IAP", runs: "gcloud compute start-iap-tunnel …", tools: ["gcloud"],
            summary: "Identity-Aware Proxy TCP forwarding to a Compute Engine instance. Needs gcloud, signed in.",
            fields: [
                Field("project", "string", required: true, "Google Cloud project ID."),
                Field("zone", "string", required: true, "Zone, e.g. asia-southeast1-a."),
                Field("instance", "string", required: true, "Instance name."),
                Field("remotePort", "integer", required: true, "Port on the instance."),
            ],
            example: .object([
                "name": .string("Analytics Postgres"), "group": .string("Production"), "localPort": .int(5433),
                "method": .object(["iap": .object([
                    "project": .string("my-project"), "zone": .string("asia-southeast1-a"),
                    "instance": .string("db-1"), "remotePort": .int(5432),
                ])]),
            ])),
        Method(
            key: "cloudflare", title: "Cloudflare Access", runs: "cloudflared access tcp --hostname … --url localhost:<port>", tools: ["cloudflared"],
            summary: "A TCP application behind Cloudflare Access. Signs in through the browser.",
            fields: [Field("hostname", "string", required: true, "The Access application's hostname, e.g. db.example.com.")],
            example: .object([
                "name": .string("Internal DB"), "group": .string("Production"), "localPort": .int(5434),
                "method": .object(["cloudflare": .object(["hostname": .string("db.example.com")])]),
            ])),
        Method(
            key: "custom", title: "Custom Command", runs: "/bin/zsh -c '<command>'", tools: [],
            summary: "Any command that holds a port open. Portkeep watches localPort and restarts the command when it stops.",
            fields: [Field("command", "string", required: true,
                           "Shell command run with zsh. {port} is replaced with localPort, e.g. tsh proxy db --port {port} mydb.")],
            example: .object([
                "name": .string("Teleport DB"), "group": .string("Development"), "localPort": .int(15432),
                "method": .object(["custom": .object(["command": .string("tsh proxy db --port {port} mydb")])]),
            ])),
    ]

    public static func method(_ key: String) -> Method? { methods.first { $0.key == key } }

    /// Defaults filled in before a new method config is decoded.
    static func defaults(for key: String) -> JSONValue {
        var object: [String: JSONValue] = [:]
        for field in method(key)?.fields ?? [] { if let value = field.defaultValue { object[field.name] = value } }
        return .object(object)
    }

    /// Defaults filled in before a new tunnel is decoded.
    static var tunnelDefaults: JSONValue {
        var object: [String: JSONValue] = [:]
        for field in tunnelFields { if let value = field.defaultValue { object[field.name] = value } }
        return .object(object)
    }

    // MARK: Output

    private static func describe(_ field: Field) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(field.name), "type": .string(field.type),
            "required": .bool(field.required), "description": .string(field.description),
        ]
        if let value = field.defaultValue { object["default"] = value }
        if let choices = field.choices { object["enum"] = .array(choices.map(JSONValue.string)) }
        if let fields = field.fields { object["fields"] = .array(fields.map(describe)) }
        return .object(object)
    }

    /// `methods.describe`: every method (or just `key`), the common fields and the JSON Schema of a tunnel.
    public static func describe(only key: String? = nil) -> JSONValue {
        let chosen = methods.filter { key == nil || $0.key == key }
        return .object([
            "tunnelFields": .array(tunnelFields.map(describe)),
            "methods": .array(chosen.map { m in
                .object([
                    "key": .string(m.key), "title": .string(m.title), "runs": .string(m.runs),
                    "summary": .string(m.summary), "tools": .array(m.tools.map(JSONValue.string)),
                    "fields": .array(m.fields.map(describe)), "example": m.example,
                ])
            }),
            "schema": tunnelSchema(),
            "notes": .array([
                "Never put passwords or secrets in a tunnel; Portkeep relies on ssh-agent, AWS/gcloud/kube sign-in and the user's config files.",
                "Ports are on 127.0.0.1. Pick a localPort that discover shows free, or one another tunnel shares on purpose.",
            ].map(JSONValue.string)),
        ])
    }

    // MARK: JSON Schema

    private static func schema(_ field: Field) -> JSONValue {
        var object: [String: JSONValue] = ["description": .string(field.description)]
        switch field.type {
        case "array": object["type"] = .string("array"); object["items"] = .object(["type": .string("string")]); object["maxItems"] = .int(1)
        case "object" where field.fields != nil:
            object.merge(objectSchema(field.fields ?? []).objectValue ?? [:]) { old, _ in old }
        default: object["type"] = .string(field.type)
        }
        if field.type == "integer", field.name.lowercased().hasSuffix("port") {
            object["minimum"] = .int(1); object["maximum"] = .int(65535)
        }
        if let value = field.defaultValue { object["default"] = value }
        if let choices = field.choices { object["enum"] = .array(choices.map(JSONValue.string)) }
        return .object(object)
    }

    private static func objectSchema(_ fields: [Field]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.name, schema($0)) })),
            "required": .array(fields.filter(\.required).map { .string($0.name) }),
            "additionalProperties": .bool(false),
        ])
    }

    /// The `method` object: exactly one method key.
    public static func methodSchema() -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for m in methods {
            var config = objectSchema(m.fields).objectValue ?? [:]
            config["description"] = .string("\(m.title): \(m.summary)")
            properties[m.key] = .object(config)
        }
        return .object([
            "type": .string("object"),
            "description": .string("Exactly one key: ssh, ssm, kubernetes, iap, cloudflare or custom."),
            "properties": .object(properties),
            "minProperties": .int(1), "maxProperties": .int(1),
            "additionalProperties": .bool(false),
        ])
    }

    /// A whole tunnel, as `tunnels.add` takes it (no id: one is assigned).
    public static func tunnelSchema() -> JSONValue {
        var object = objectSchema(tunnelFields).objectValue ?? [:]
        var properties = object["properties"]?.objectValue ?? [:]
        var method = methodSchema().objectValue ?? [:]
        method["description"] = properties["method"]?["description"]
        properties["method"] = .object(method)
        object["properties"] = .object(properties)
        return .object(object)
    }

    /// Every field allowed in a patch, minus `method` (any key may change).
    public static func patchSchema() -> JSONValue {
        var object = tunnelSchema().objectValue ?? [:]
        object["required"] = .array([])
        object["description"] = .string("Only the fields to change (JSON merge patch). A method object with a different key replaces the method; null removes an optional field.")
        return .object(object)
    }

    // MARK: Unknown keys

    /// Names the first key that no field has, e.g. `method.ssh.port`, so a typo is an error rather than ignored.
    static func unknownKey(in tunnel: JSONValue) -> String? {
        let readOnly: Set<String> = ["id", "state", "status", "connectedSince", "reason", "hint", "attempt", "blockedBy"]
        func check(_ value: JSONValue?, _ fields: [Field], _ path: String) -> String? {
            guard let object = value?.objectValue else { return nil }
            for (key, child) in object.sorted(by: { $0.key < $1.key }) {
                let name = path.isEmpty ? key : "\(path).\(key)"
                if path.isEmpty, readOnly.contains(key) { continue }
                if path.isEmpty, key == "method" {
                    for (methodKey, config) in child.objectValue ?? [:] {
                        guard let m = method(methodKey) else { return "method.\(methodKey)" }
                        if let bad = check(config, m.fields, "method.\(methodKey)") { return bad }
                    }
                    continue
                }
                guard let field = fields.first(where: { $0.name == key }) else { return name }
                if let sub = field.fields, let bad = check(child, sub, name) { return bad }
            }
            return nil
        }
        return check(tunnel, tunnelFields, "")
    }
}
