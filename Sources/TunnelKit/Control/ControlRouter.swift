import Foundation

/// What the control socket drives: the app's TunnelStore, or a fake in tests. Everything runs on
/// the main actor, so a change from the socket is the same as one from the editor and the UI
/// follows it live.
@MainActor
public protocol ControlBackend: AnyObject {
    var file: TunnelFile { get }
    /// tunnels.json is from a newer Portkeep: nothing may be saved.
    var readOnly: Bool { get }
    var ports: any PortChecking { get }
    func state(of id: UUID) -> TunnelState
    /// Switched on by the user, even while it retries.
    func isOn(_ id: UUID) -> Bool
    /// Adds the tunnel, or replaces the one with its id (restarting it when how it connects changed).
    func save(_ tunnel: Tunnel) async
    func delete(_ id: UUID) async
    func duplicate(_ id: UUID) -> UUID?
    /// One tunnel per local port: switching on one that shares a port switches the other off.
    func switchOn(_ ids: [UUID]) async
    func turnOff(_ id: UUID) async
    /// Connects once and stops, as the editor's Test Connection does.
    func test(_ tunnel: Tunnel) async -> (state: TunnelState, log: [String])
    func log(for id: UUID) -> [String]
    func addGroup(_ name: String, hex: String)
    func addTag(_ name: String, hex: String)
    func discover() async -> Discovery
}

/// The control socket's JSON-RPC methods, over a `ControlBackend`. One request line in, one
/// response line out (none for a notification).
@MainActor
public final class ControlRouter {
    private let backend: any ControlBackend
    /// How long start/toggle wait by default for tunnels to connect or fail.
    public var defaultWait: Double = 15
    public static let methodNames = [
        "tunnels.list", "tunnels.get", "tunnels.add", "tunnels.update", "tunnels.remove", "tunnels.duplicate",
        "tunnels.start", "tunnels.stop", "tunnels.toggle", "tunnels.test", "tunnels.logs",
        "groups.list", "groups.add", "tags.list", "tags.add", "status", "methods.describe", "discover",
    ]

    public init(backend: any ControlBackend) {
        self.backend = backend
    }

    public func handle(_ line: Data) async -> Data? {
        let request: RPCRequest
        do {
            request = try JSONDecoder().decode(RPCRequest.self, from: line)
        } catch {
            let code = (try? JSONDecoder().decode(JSONValue.self, from: line)) == nil ? RPCError.parseError : RPCError.invalidRequest
            return RPCResponse(id: .null, error: RPCError(code, code == RPCError.parseError
                ? "Not JSON." : "Not a JSON-RPC 2.0 request: needs jsonrpc, method and id.")).line()
        }
        let outcome: Result<JSONValue, RPCError>
        do {
            outcome = .success(try await call(request.method, request.params ?? .object([:])))
        } catch {
            outcome = .failure(error)
        }
        guard let id = request.id else { return nil }
        switch outcome {
        case .success(let result): return RPCResponse(id: id, result: result).line()
        case .failure(let error): return RPCResponse(id: id, error: error).line()
        }
    }

    public func call(_ method: String, _ params: JSONValue) async throws(RPCError) -> JSONValue {
        guard params.objectValue != nil else { throw RPCError(RPCError.invalidParams, "params must be a JSON object.") }
        switch method {
        case "tunnels.list": return list(params)
        case "tunnels.get": return info(try resolve(params))
        case "tunnels.add": return try await add(params)
        case "tunnels.update": return try await update(params)
        case "tunnels.remove": return try await remove(params)
        case "tunnels.duplicate": return try await duplicate(params)
        case "tunnels.start": return try await switchTunnels(params, on: true)
        case "tunnels.stop": return try await switchTunnels(params, on: false)
        case "tunnels.toggle": return try await switchTunnels(params, on: nil)
        case "tunnels.test": return try await test(params)
        case "tunnels.logs": return try logs(params)
        case "groups.list": return groups()
        case "tags.list": return tags()
        case "groups.add": return try addLabel(params, group: true)
        case "tags.add": return try addLabel(params, group: false)
        case "status": return status()
        case "methods.describe": return try describe(params)
        case "discover": return await discover()
        default:
            throw RPCError(RPCError.methodNotFound, "Unknown method \(method). Methods: \(Self.methodNames.joined(separator: ", ")).")
        }
    }

    // MARK: Reads

    private var tunnels: [Tunnel] { backend.file.tunnels }

    /// A tunnel as in tunnels.json, plus what it is doing now.
    func info(_ tunnel: Tunnel) -> JSONValue {
        var object = (try? JSONValue(encoding: tunnel))?.objectValue ?? [:]
        let state = backend.state(of: tunnel.id)
        object["state"] = .string(StatusSnapshot.stateName(state))
        object["status"] = .string(statusLine(state, tunnel: tunnel, now: .now))
        switch state {
        case .connected(let since):
            object["connectedSince"] = .string(since.formatted(.iso8601))
        case .retrying(let reason, let attempt, _):
            object["reason"] = .string(Self.code(reason))
            object["hint"] = .string(Self.hint(reason, tunnel: tunnel))
            object["attempt"] = .int(attempt)
        case .failed(let reason):
            object["reason"] = .string(Self.code(reason))
            object["hint"] = .string(Self.hint(reason, tunnel: tunnel))
        case .blocked(let owner):
            object["reason"] = .string("portInUse")
            if let owner { object["blockedBy"] = .object(["pid": .int(Int(owner.pid)), "command": .string(owner.command)]) }
            object["hint"] = .string(blockedHint(tunnel, owner: owner))
        default:
            break
        }
        return .object(object)
    }

    private func list(_ params: JSONValue) -> JSONValue {
        var chosen = tunnels
        if let group = params["group"]?.stringValue {
            chosen = chosen.filter { $0.group.caseInsensitiveCompare(group) == .orderedSame }
        }
        if let tag = params["tag"]?.stringValue {
            chosen = chosen.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        }
        return .object(["tunnels": .array(chosen.map(info))])
    }

    private func status() -> JSONValue {
        let entries = tunnels.map { tunnel in
            let state = backend.state(of: tunnel.id)
            var since: Date?
            if case .connected(let date) = state { since = date }
            return StatusSnapshot.Entry(
                id: tunnel.id, name: tunnel.name, group: tunnel.group, port: tunnel.localPort,
                state: StatusSnapshot.stateName(state), status: statusLine(state, tunnel: tunnel, now: .now),
                connectedSince: since)
        }
        return (try? JSONValue(encoding: StatusSnapshot(pid: getpid(), running: true, tunnels: entries))) ?? .null
    }

    private func groups() -> JSONValue {
        let file = backend.file
        var names = file.groups
        for t in file.tunnels where !names.contains(t.group) { names.append(t.group) }
        return .object(["groups": .array(names.map { name in
            var object: [String: JSONValue] = [
                "name": .string(name), "tunnels": .int(file.tunnels.filter { $0.group == name }.count),
            ]
            if let hex = file.groupColors[name] { object["color"] = .string(hex) }
            return .object(object)
        })])
    }

    private func tags() -> JSONValue {
        let file = backend.file
        return .object(["tags": .array(file.allTags.map { name in
            .object([
                "name": .string(name), "color": .string(file.tagColor(name)),
                "tunnels": .int(file.tunnels.filter { $0.tags.contains(name) }.count),
            ])
        })])
    }

    private func logs(_ params: JSONValue) throws(RPCError) -> JSONValue {
        let tunnel = try resolve(params)
        let count = min(max(params["lines"]?.intValue ?? 50, 1), LogBuffer.capacity)
        return .object(["lines": .array(backend.log(for: tunnel.id).suffix(count).map(JSONValue.string))])
    }

    private func describe(_ params: JSONValue) throws(RPCError) -> JSONValue {
        let key = params["method"]?.stringValue
        if let key, MethodCatalog.method(key) == nil {
            throw .invalid("Unknown method \(key). Use ssh, ssm, kubernetes, iap, cloudflare or custom.", field: "method")
        }
        return MethodCatalog.describe(only: key)
    }

    private func discover() async -> JSONValue {
        let found = await backend.discover()
        var object = (try? JSONValue(encoding: found))?.objectValue ?? [:]
        object["groups"] = groups()["groups"]
        object["tags"] = .array(backend.file.allTags.map(JSONValue.string))
        object["tunnelPorts"] = .array(tunnels.map {
            .object(["port": .int($0.localPort), "name": .string($0.name)])
        })
        return .object(object)
    }

    // MARK: Writes

    private func writable() throws(RPCError) {
        if backend.readOnly {
            throw RPCError(RPCError.readOnly, "tunnels.json was written by a newer Portkeep, so changes can’t be saved. Update Portkeep.")
        }
    }

    private func add(_ params: JSONValue) async throws(RPCError) -> JSONValue {
        try writable()
        let input = params["tunnel"] ?? params.objectValue.map { object in
            JSONValue.object(object.filter { $0.key != "start" && $0.key != "wait" })
        } ?? params
        let tunnel = try TunnelInput.newTunnel(from: input, in: backend.file)
        await backend.save(tunnel)
        var result: [String: JSONValue] = ["warnings": .array(await warnings(for: tunnel).map(JSONValue.string))]
        if params["start"]?.boolValue == true {
            await backend.switchOn([tunnel.id])
            await settle([tunnel.id], timeout: wait(params))
        }
        result["tunnel"] = info(backend.file.tunnels.first { $0.id == tunnel.id } ?? tunnel)
        return .object(result)
    }

    private func update(_ params: JSONValue) async throws(RPCError) -> JSONValue {
        try writable()
        let old = try resolve(params)
        guard let patch = params["patch"] else {
            throw .invalid("tunnels.update needs patch: the fields to change, e.g. {\"localPort\": 3307}.", field: "patch")
        }
        let tunnel = try TunnelInput.updated(old, patch: patch, in: backend.file)
        await backend.save(tunnel)
        let warnings = tunnel.localPort == old.localPort ? [] : await warnings(for: tunnel)
        return .object(["tunnel": info(tunnel), "warnings": .array(warnings.map(JSONValue.string))])
    }

    private func remove(_ params: JSONValue) async throws(RPCError) -> JSONValue {
        try writable()
        let tunnel = try resolve(params)
        await backend.delete(tunnel.id)
        return .object(["removed": .object(["id": .string(tunnel.id.uuidString), "name": .string(tunnel.name)])])
    }

    private func duplicate(_ params: JSONValue) async throws(RPCError) -> JSONValue {
        try writable()
        let original = try resolve(params)
        guard let id = backend.duplicate(original.id), var copy = tunnels.first(where: { $0.id == id }) else {
            throw RPCError(RPCError.internalError, "Couldn’t duplicate \(original.name).")
        }
        if let name = params["name"]?.stringValue {
            do {
                copy = try TunnelInput.updated(copy, patch: .object(["name": .string(name)]), in: backend.file)
            } catch {
                await backend.delete(id)
                throw error
            }
            await backend.save(copy)
        }
        return .object(["tunnel": info(copy)])
    }

    private func test(_ params: JSONValue) async throws(RPCError) -> JSONValue {
        let tunnel: Tunnel
        if let config = params["config"] {
            // Not saved: checked as an add would be, without the name clash.
            tunnel = try TunnelInput.newTunnel(from: config, in: TunnelFile(tunnels: []))
        } else {
            tunnel = try resolve(params)
        }
        let (state, log) = await backend.test(tunnel)
        var object = info(tunnel, as: state)
        object["ok"] = .bool({ if case .connected = state { true } else { false } }())
        object["log"] = .array(log.suffix(40).map(JSONValue.string))
        return .object(object)
    }

    /// `info` for a state the backend doesn't hold (a test run).
    private func info(_ tunnel: Tunnel, as state: TunnelState) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "name": .string(tunnel.name), "localPort": .int(tunnel.localPort),
            "state": .string(StatusSnapshot.stateName(state)),
            "status": .string(statusLine(state, tunnel: tunnel, now: .now)),
        ]
        switch state {
        case .failed(let reason), .retrying(let reason, _, _):
            object["reason"] = .string(Self.code(reason))
            object["hint"] = .string(Self.hint(reason, tunnel: tunnel))
        case .blocked(let owner):
            object["reason"] = .string("portInUse")
            object["hint"] = .string(blockedHint(tunnel, owner: owner))
        default:
            break
        }
        return object
    }

    private func switchTunnels(_ params: JSONValue, on: Bool?) async throws(RPCError) -> JSONValue {
        let chosen = try targets(params)
        let ids = chosen.map(\.id)
        let turnOn = on ?? !ids.contains(where: backend.isOn)
        if turnOn {
            await backend.switchOn(ids)
            await settle(ids, timeout: wait(params))
        } else {
            for id in ids where backend.isOn(id) { await backend.turnOff(id) }
            await settle(ids, timeout: min(wait(params), 5))
        }
        let current = Set(ids)
        return .object(["tunnels": .array(tunnels.filter { current.contains($0.id) }.map(info))])
    }

    private func addLabel(_ params: JSONValue, group: Bool) throws(RPCError) -> JSONValue {
        try writable()
        let kind = group ? "group" : "tag"
        let raw = params["name"]?.stringValue ?? ""
        guard let name = group ? Optional(raw.trimmingCharacters(in: .whitespaces)).flatMap({ $0.isEmpty ? nil : $0 })
                               : Tunnel.parseTags(raw).first else {
            throw .invalid("A \(kind) needs a name.", field: "name")
        }
        let existing = group ? groups()["groups"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [] : backend.file.allTags
        if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw RPCError(RPCError.conflict, "There is already a \(kind) named \(name).", data: .object(["field": .string("name")]))
        }
        var hex = LabelColor.defaultHex(for: name)
        if let color = params["color"]?.stringValue {
            guard let rgb = LabelColor.components(color) else {
                throw .invalid("color should be #RRGGBB, e.g. #34C759.", field: "color")
            }
            hex = LabelColor.hex(red: rgb.0, green: rgb.1, blue: rgb.2)
        }
        if group { backend.addGroup(name, hex: hex) } else { backend.addTag(name, hex: hex) }
        return .object(["name": .string(name), "color": .string(hex)])
    }

    // MARK: Helpers

    private func wait(_ params: JSONValue) -> Double {
        if case .number(let seconds) = params["wait"] { return min(max(seconds, 0), 60) }
        return defaultWait
    }

    /// Waits until each tunnel switched on has connected, failed, been blocked or is standing by,
    /// and each switched off is off, or until `timeout`.
    private func settle(_ ids: [UUID], timeout: Double) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            let done = ids.allSatisfy { id in
                let state = backend.state(of: id)
                switch state {
                case .checking, .starting: return false
                case .off: return !backend.isOn(id)
                default: return backend.isOn(id)
                }
            }
            if done { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// `params.tunnel` as a name (ignoring case) or an id.
    func resolve(_ params: JSONValue) throws(RPCError) -> Tunnel {
        guard let reference = params["tunnel"]?.stringValue ?? params["name"]?.stringValue ?? params["id"]?.stringValue,
              !reference.isEmpty else {
            throw .invalid("Say which tunnel: tunnel is its name or id.", field: "tunnel")
        }
        let matches = RemoteCommand.Target.tunnel(reference).tunnels(in: tunnels)
        if matches.count > 1 {
            throw RPCError(RPCError.conflict,
                           "\(matches.count) tunnels are named \(reference). Use an id: \(matches.map(\.id.uuidString).joined(separator: ", ")).")
        }
        guard let tunnel = matches.first else {
            let names = tunnels.map(\.name)
            throw RPCError(RPCError.notFound, names.isEmpty
                ? "No tunnel named \(reference). There are no tunnels yet."
                : "No tunnel named \(reference). Tunnels: \(names.joined(separator: ", ")).")
        }
        return tunnel
    }

    /// `tunnel`, `group` or `all: true`.
    private func targets(_ params: JSONValue) throws(RPCError) -> [Tunnel] {
        if params["all"]?.boolValue == true { return tunnels }
        if let group = params["group"]?.stringValue {
            let matches = RemoteCommand.Target.group(group).tunnels(in: tunnels)
            guard !matches.isEmpty else {
                let names = Set(tunnels.map(\.group)).sorted()
                throw RPCError(RPCError.notFound, "No group named \(group) has tunnels. Groups with tunnels: \(names.joined(separator: ", ")).")
            }
            return matches
        }
        return [try resolve(params)]
    }

    private func warnings(for tunnel: Tunnel) async -> [String] {
        let port = tunnel.localPort
        let sharing = tunnels.filter { $0.id != tunnel.id && $0.localPort == port }
        if !sharing.isEmpty {
            return ["Port \(port) is shared with \(sharing.map(\.name).joined(separator: ", ")). Only one of them runs at a time: switching one on switches the others off."]
        }
        guard !backend.isOn(tunnel.id), !backend.ports.isFree(port) else { return [] }
        let owner = await backend.ports.owner(of: port)
        return [blockedHint(tunnel, owner: owner)]
    }

    private func blockedHint(_ tunnel: Tunnel, owner: PortOwner?) -> String {
        let port = tunnel.localPort
        let ports = backend.ports
        let taken = Set(tunnels.map(\.localPort))
        let free = PortProbe.alternate(for: port) { !taken.contains($0) && ports.isFree($0) }
        let who = owner.map { "\($0.command) (pid \($0.pid))" } ?? "another process"
        return "Port \(port) is in use by \(who), so \(tunnel.name) can’t start while it is. Stop that process, or move the tunnel to a free port such as \(free) (update localPort)."
    }

    /// A stable name for a failure, for scripts and agents.
    nonisolated public static func code(_ reason: FailureReason) -> String {
        switch reason {
        case .hostKeyChanged: "hostKeyChanged"
        case .authFailed: "authFailed"
        case .ssoExpired: "ssoExpired"
        case .pluginMissing: "pluginMissing"
        case .forwardRefused: "forwardRefused"
        case .hostUnreachable: "hostUnreachable"
        case .portInUse: "portInUse"
        case .toolMissing: "toolMissing"
        case .readinessTimeout: "readinessTimeout"
        case .stoppedResponding: "stoppedResponding"
        case .unknown: "exited"
        }
    }

    /// What to do about a failure, in English, with the command to run when there is one.
    nonisolated public static func hint(_ reason: FailureReason, tunnel: Tunnel) -> String {
        let host = tunnel.remoteName
        switch reason {
        case .hostKeyChanged:
            return "The SSH host key for \(host) changed. Confirm with whoever runs the server that this was expected before trusting it, then remove the old key: ssh-keygen -R \(host)"
        case .authFailed:
            return "\(host) refused the SSH key. Load it into the agent (ssh-add --apple-use-keychain ~/.ssh/id_ed25519) or set method.ssh.identityFile. Passwords aren't supported."
        case .ssoExpired(let profile):
            return "The AWS SSO session expired. Run: aws sso login --profile \(profile ?? "default") — then start the tunnel again."
        case .pluginMissing:
            return "AWS session-manager-plugin is missing. Install it: brew install --cask session-manager-plugin"
        case .forwardRefused:
            return "The server refused the forward: TCP forwarding may be disabled there (AllowTcpForwarding), or for remote mode the port is taken on the server."
        case .hostUnreachable:
            return "Couldn’t reach \(host). Check the VPN, the host name and the network; Portkeep keeps retrying."
        case .portInUse:
            return "Another process took port \(tunnel.localPort). Stop it, or change localPort."
        case .toolMissing(let missing):
            return "\(missing.tool) isn’t installed. Install it: \(missing.installHint)"
        case .readinessTimeout:
            return "The command ran but port \(tunnel.localPort) didn’t open within 20 seconds. Read the log (tunnels.logs) for why."
        case .stoppedResponding:
            return "It was connected, then stopped answering; Portkeep is reconnecting."
        case .unknown(let status):
            return "The command exited with status \(status). Read the log (tunnels.logs) for why."
        }
    }
}
