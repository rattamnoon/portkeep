import Foundation

/// `portkeep mcp`: a Model Context Protocol server over stdio (spec 2025-06-18). Each tool forwards
/// to a control-socket method through `call`, so the running app does the work and the menu bar
/// follows along. Messages are single JSON lines; nothing else goes to stdout.
public final class MCPServer {
    /// A control-socket method and its params → its result, or a thrown `RPCError`.
    public typealias Call = (_ method: String, _ params: JSONValue) throws(RPCError) -> JSONValue

    public static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let version: String
    private let call: Call
    public private(set) var negotiatedVersion: String?

    public init(version: String, call: @escaping Call) {
        self.version = version
        self.call = call
    }

    public static let instructions = """
        Portkeep keeps named port forwards (SSH -L/-R/-D with ProxyJump, AWS SSM, kubectl port-forward, \
        Google Cloud IAP, Cloudflare Access, custom commands) running from the macOS menu bar.
        To add a tunnel: call discover (SSH hosts, AWS profiles, kube contexts, ports in use) and describe_methods \
        (fields, defaults and an example per method), then add_tunnel, then test_tunnel or start_tunnel and read \
        the result's state, status and hint; tunnel_logs shows the command's output.
        Ask the user before remove_tunnel. Never put passwords, tokens or other secrets in a tunnel: Portkeep \
        relies on ssh-agent, AWS SSO / gcloud / kubectl sign-in and the user's own config files.
        When a result has a hint with a command for the user to run (aws sso login, ssh-add, ssh-keygen -R), \
        tell the user rather than running it unasked.
        """

    // MARK: Tools

    public struct Tool: Sendable {
        public var name: String
        public var title: String
        public var description: String
        public var inputSchema: JSONValue
        public var readOnly: Bool
        public var destructive: Bool
        public var idempotent: Bool
        /// The control-socket method it forwards to, with the arguments as params.
        public var control: String
    }

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    private static func prop(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static let tunnelRef = prop("string", "The tunnel's name (ignoring case) or id.")
    private static let waitProp = prop("number", "Seconds to wait for it to connect or fail (0–60, default 15).")

    public static let tools: [Tool] = [
        Tool(name: "list_tunnels", title: "List tunnels",
             description: "Every tunnel with its settings and what it is doing now: state (off, connecting, connected, standing-by, reconnecting, blocked, failed), status line, and for problems a reason code and a hint saying what to do.",
             inputSchema: object(["group": prop("string", "Only this group."), "tag": prop("string", "Only tunnels with this tag.")]),
             readOnly: true, destructive: false, idempotent: true, control: "tunnels.list"),
        Tool(name: "get_tunnel", title: "Get a tunnel",
             description: "One tunnel's settings and current state.",
             inputSchema: object(["tunnel": tunnelRef], required: ["tunnel"]),
             readOnly: true, destructive: false, idempotent: true, control: "tunnels.get"),
        Tool(name: "add_tunnel", title: "Add a tunnel",
             description: "Saves a new tunnel (switched off unless start is true). Call discover and describe_methods first to fill the method's fields with the user's real hosts, profiles and contexts. Never include passwords or secrets. Warnings report a local port that is shared or in use.",
             inputSchema: object([
                "tunnel": MethodCatalog.tunnelSchema(),
                "start": prop("boolean", "Switch it on after saving (default false)."),
                "wait": waitProp,
             ], required: ["tunnel"]),
             readOnly: false, destructive: false, idempotent: false, control: "tunnels.add"),
        Tool(name: "update_tunnel", title: "Change a tunnel",
             description: "Changes some of a tunnel's fields (JSON merge patch). A running tunnel restarts only when how it connects changes.",
             inputSchema: object(["tunnel": tunnelRef, "patch": MethodCatalog.patchSchema()], required: ["tunnel", "patch"]),
             readOnly: false, destructive: false, idempotent: true, control: "tunnels.update"),
        Tool(name: "remove_tunnel", title: "Remove a tunnel",
             description: "Stops and deletes a tunnel. It can't be undone: confirm with the user first.",
             inputSchema: object(["tunnel": tunnelRef], required: ["tunnel"]),
             readOnly: false, destructive: true, idempotent: true, control: "tunnels.remove"),
        Tool(name: "duplicate_tunnel", title: "Duplicate a tunnel",
             description: "Copies a tunnel, switched off, named \"<name> copy\" unless name is given. Use it to make the same tunnel for another environment, then update_tunnel.",
             inputSchema: object(["tunnel": tunnelRef, "name": prop("string", "Name for the copy.")], required: ["tunnel"]),
             readOnly: false, destructive: false, idempotent: false, control: "tunnels.duplicate"),
        Tool(name: "start_tunnel", title: "Start tunnels",
             description: "Switches on a tunnel, a group or all, and waits for them to connect or fail. Tunnels sharing a local port switch each other off. Read state, status and hint in the result.",
             inputSchema: object([
                "tunnel": tunnelRef, "group": prop("string", "Every tunnel in this group."),
                "all": prop("boolean", "Every tunnel."), "wait": waitProp,
             ]),
             readOnly: false, destructive: false, idempotent: true, control: "tunnels.start"),
        Tool(name: "stop_tunnel", title: "Stop tunnels",
             description: "Switches off a tunnel, a group or all.",
             inputSchema: object([
                "tunnel": tunnelRef, "group": prop("string", "Every tunnel in this group."), "all": prop("boolean", "Every tunnel."),
             ]),
             readOnly: false, destructive: false, idempotent: true, control: "tunnels.stop"),
        Tool(name: "test_tunnel", title: "Test a connection",
             description: "Connects once and stops again, as the editor's Test Connection does: a saved tunnel (tunnel), or a configuration that isn't saved yet (config, same shape as add_tunnel's tunnel). Returns ok, state, status, reason, hint and the log.",
             inputSchema: object(["tunnel": tunnelRef, "config": MethodCatalog.tunnelSchema()]),
             readOnly: true, destructive: false, idempotent: true, control: "tunnels.test"),
        Tool(name: "tunnel_logs", title: "Tunnel log",
             description: "The last lines the tunnel's command printed (stdout and stderr), for working out why it failed.",
             inputSchema: object(["tunnel": tunnelRef, "lines": prop("integer", "How many lines (default 50, at most 500).")], required: ["tunnel"]),
             readOnly: true, destructive: false, idempotent: true, control: "tunnels.logs"),
        Tool(name: "list_groups", title: "List groups",
             description: "Groups (environments or projects) with their colours and how many tunnels each has.",
             inputSchema: object([:]), readOnly: true, destructive: false, idempotent: true, control: "groups.list"),
        Tool(name: "list_tags", title: "List tags",
             description: "Tags with their colours and how many tunnels have each.",
             inputSchema: object([:]), readOnly: true, destructive: false, idempotent: true, control: "tags.list"),
        Tool(name: "add_group", title: "Add a group",
             description: "Adds an empty group. add_tunnel creates a group it names anyway; use this to choose its colour.",
             inputSchema: object(["name": prop("string", "Group name."), "color": prop("string", "#RRGGBB.")], required: ["name"]),
             readOnly: false, destructive: false, idempotent: false, control: "groups.add"),
        Tool(name: "add_tag", title: "Add a tag",
             description: "Adds a tag with a colour.",
             inputSchema: object(["name": prop("string", "Tag name."), "color": prop("string", "#RRGGBB.")], required: ["name"]),
             readOnly: false, destructive: false, idempotent: false, control: "tags.add"),
        Tool(name: "describe_methods", title: "Describe connection methods",
             description: "For each connection method (ssh, ssm, kubernetes, iap, cloudflare, custom): its fields with types, defaults and meanings, the tools it needs, and an example tunnel. Read this before add_tunnel.",
             inputSchema: object(["method": .object([
                "type": .string("string"), "enum": .array(MethodCatalog.methods.map { .string($0.key) }),
                "description": .string("Only this method."),
             ])]),
             readOnly: true, destructive: false, idempotent: true, control: "methods.describe"),
        Tool(name: "discover", title: "Discover what's configured",
             description: "What this Mac already has: Host aliases in ~/.ssh/config, AWS profiles with regions, kubectl contexts, which tools are installed (and how to install the rest), groups, tags and the local ports tunnels use.",
             inputSchema: object([:]), readOnly: true, destructive: false, idempotent: true, control: "discover"),
    ]

    static func describe(_ tool: Tool) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "title": .string(tool.title),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
            "annotations": .object([
                "title": .string(tool.title),
                "readOnlyHint": .bool(tool.readOnly),
                "destructiveHint": .bool(tool.destructive),
                "idempotentHint": .bool(tool.idempotent),
                // Only this Mac's Portkeep, though tunnels then reach other hosts.
                "openWorldHint": .bool(false),
            ]),
        ])
    }

    // MARK: Messages

    /// Answers one line from the client: a response line, or nil for a notification or a response.
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return RPCResponse(id: .null, error: RPCError(RPCError.parseError, "Not JSON.")).lineString()
        }
        guard let method = message["method"]?.stringValue else {
            // A response to something we sent (we send nothing), or junk.
            if message["id"] != nil, message["result"] != nil || message["error"] != nil { return nil }
            return RPCResponse(id: message["id"] ?? .null,
                               error: RPCError(RPCError.invalidRequest, "Not a JSON-RPC 2.0 request.")).lineString()
        }
        let params = message["params"] ?? .object([:])
        guard let id = message["id"], id != .null else {
            // Notifications (initialized, cancelled): nothing to answer.
            return nil
        }
        do {
            return RPCResponse(id: id, result: try respond(method, params)).lineString()
        } catch {
            return RPCResponse(id: id, error: error).lineString()
        }
    }

    private func respond(_ method: String, _ params: JSONValue) throws(RPCError) -> JSONValue {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            // The client's version when we speak it, otherwise our latest; the client decides whether to go on.
            let chosen = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            negotiatedVersion = chosen
            return .object([
                "protocolVersion": .string(chosen),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("portkeep"), "title": .string("Portkeep"), "version": .string(version)]),
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return .object([:])
        case "tools/list":
            return .object(["tools": .array(Self.tools.map(Self.describe))])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                throw RPCError(RPCError.invalidParams, "tools/call needs a tool name.")
            }
            guard let tool = Self.tools.first(where: { $0.name == name }) else {
                throw RPCError(RPCError.invalidParams, "Unknown tool \(name).")
            }
            let arguments = params["arguments"] ?? .object([:])
            guard arguments.objectValue != nil else {
                return Self.toolError("arguments must be a JSON object.")
            }
            do {
                let result = try call(tool.control, arguments)
                var content: [String: JSONValue] = [
                    "content": .array([.object(["type": .string("text"), "text": .string(result.prettyText())])]),
                    "isError": .bool(false),
                ]
                if result.objectValue != nil { content["structuredContent"] = result }
                return .object(content)
            } catch {
                // Errors from the tool go back as its result, so the model can read and fix them.
                var text = error.message
                if let field = error.data?["field"]?.stringValue { text += " (field: \(field))" }
                return Self.toolError(text)
            }
        case "resources/list":
            return .object(["resources": .array([])])
        case "prompts/list":
            return .object(["prompts": .array([])])
        default:
            throw RPCError(RPCError.methodNotFound, "Method not found: \(method)")
        }
    }

    private static func toolError(_ text: String) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(true),
        ])
    }
}

extension RPCResponse {
    func lineString() -> String { String(decoding: line(), as: UTF8.self) }
}
